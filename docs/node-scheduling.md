# Node Roles & Scheduling

How workloads are placed on this cluster: node roles, the control-plane taint,
hardware-class labels, and the taints/tolerations/affinity model behind them.

## Node inventory

| Node | Role | CPU | `node-class` | Notes |
|------|------|-----|--------------|-------|
| ipc1 | **control-plane,etcd** | Pentium G5400T, 2c/4t, 32G | `standard` | etcd cluster-init seed; SSH bastion; tainted, runs no workloads |
| ipc2 | **control-plane,etcd** | Pentium G5400T, 2c/4t, 32G | `standard` | HA control-plane member (joined 2026-06-28); tainted |
| ipc3 | **control-plane,etcd** | Pentium G5400T, 2c/4t, 32G | `standard` | HA control-plane member (joined 2026-06-28); tainted |
| ipc4 | worker | i5-12500T, 6c/12t, 32G | `performance` | |
| ipc5 | worker | i5-12500T, 6c/12t, 32G | `performance` | |
| ipc6 | worker | i5-12500T, 6c/12t, 32G | `performance` | RAM upgraded to 2×16 GiB (was 16G) |

## HA control plane on ipc1-3 (embedded etcd)

As of **2026-06-28** the control plane is **3-node HA on embedded etcd** (ipc1-3),
migrated from the old single-server SQLite on ipc1. See
`ipc1-3-control-plane-ha-runbook.md` for how it was done. The slow Pentium nodes
are dedicated to control-plane duty (etcd is light on CPU/RAM); all real workloads
run on the i5 performance nodes ipc4-6.

The weak 2-core Pentiums are *also* the API servers / etcd members, so they are
repelled from workloads:

- **Taints (both, on all three):** `node-role.kubernetes.io/control-plane:NoSchedule`
  **and** `slow:NoSchedule`.
- **Durable:** set as `node-taint:` in the server configs (`config/k3s-server.yaml`
  for ipc1's cluster-init seed, `config/k3s-server-join.yaml` for ipc2/ipc3). k3s
  applies node-taints at **registration**, so they survive a reinstall — a live
  `kubectl taint` does **not**. (The `slow` taint used to be live-only; it is now
  persisted in config.)
- What still runs on ipc1-3: DaemonSets (node-exporter, spire-agent) and any addon
  that explicitly **tolerates** these taints. Everything else schedules on ipc4-6.

### Control-plane endpoint HA

- **In-cluster (workers → API): HA.** k3s's embedded client-side load balancer on
  each agent fails over across all three servers automatically (no external LB
  needed) — verified in the agent LB state listing ipc1/ipc2/ipc3.
- **External clients (kubeconfig): HA via kube-vip (since 2026-06-28).** A floating
  VIP `192.168.88.58` (`k8s-api.home.skeptomai.com`) is advertised across ipc1-3 by a
  kube-vip DaemonSet; the apiserver cert carries it in `tls-san`. omen has an additive
  `ipc-vip` kubeconfig context for it (the `default` context still uses the tailnet
  `ipc1:6443` path, which is reachable anywhere but not HA). kube-vip is bound to each
  node's local apiserver so it fails over on an apiserver outage too (not just node
  down) — full detail in **`kube-vip.md`**. Pairs with **MetalLB** (deployed 2026-06-28,
  pool `192.168.88.240-.250`, `docs/metallb.md`) for LoadBalancer service IPs / the
  Kamaji work — k3s ServiceLB is now disabled and Traefik runs on a MetalLB IP.

## Scheduling by hardware class

Every node is labelled `node-class` (`standard` = Pentium, `performance` = i5).
`scripts/label-nodes.sh` is the idempotent source of truth — re-run it after a
node reinstall (labels are live cluster state and don't survive a fresh
registration).

Pin a heavy workload to the i5s (**hard** — won't schedule elsewhere):
```yaml
spec:
  nodeSelector:
    node-class: performance
```

*Prefer* the i5s but allow fallback (**soft**):
```yaml
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - { key: node-class, operator: In, values: [performance] }
```

Park light/background work on the Pentiums with `nodeSelector: {node-class:
standard}` (lands on ipc2/3 — ipc1 is tainted regardless).

## The model (reference)

Four mechanisms, two directions:

|                       | **Hard**                                   | **Soft**                          |
|-----------------------|--------------------------------------------|-----------------------------------|
| **Node repels pod**   | taint `NoSchedule` / `NoExecute`           | taint `PreferNoSchedule`          |
| **Pod seeks node**    | `nodeSelector` / nodeAffinity `required`   | nodeAffinity `preferred`          |

- **Taints** live on the *node* (`key=value:effect`) and repel pods.
  **Tolerations** live on the *pod* and are *permission* to ignore a taint — not
  attraction. To land on a tainted node you often need **both** a toleration (to
  be allowed) and affinity (to be chosen).
- **Toleration operators:** `Equal` (key+value+effect must match) or `Exists`
  (match the key, any value; omit the key too → tolerate *every* taint — the
  blanket DaemonSet pattern, e.g. node-exporter, and now spire-agent).
- **nodeSelector** = hard, exact label match. **nodeAffinity** = the expressive
  version: `required` (hard) or `preferred` (soft, weighted), with operators
  `In/NotIn/Exists/DoesNotExist/Gt/Lt`.
- **podAffinity / podAntiAffinity** = the other axis — schedule relative to
  *other pods* (co-locate or spread), not nodes.

### When are these rechecked? (`...IgnoredDuringExecution`)

- **nodeAffinity / nodeSelector / `NoSchedule` taints**: evaluated **only at
  scheduling time**, never re-checked on running pods. Relabel or taint a node
  and existing pods stay put. (`RequiredDuringExecution` for nodeAffinity was
  never implemented — the long name reserves space for it.) This is *why* we had
  to `drain` ipc1 by hand after tainting it.
- **`NoExecute` taints**: the **one** thing enforced *during* execution. The
  **taint manager** (in kube-controller-manager) reacts via informer watches and
  evicts running pods that don't tolerate the taint — immediately, or after the
  pod's `tolerationSeconds`. It **deletes** pods directly (honours
  `terminationGracePeriodSeconds` but **bypasses PodDisruptionBudgets**), unlike
  `drain` which uses the PDB-respecting Eviction API.
  - Node failure uses this path: the node lifecycle controller **polls** node
    health every `--node-monitor-period` (5s) against a ~40s heartbeat grace
    period, stamps `unreachable:NoExecute` when a node goes dark, then the
    (event-driven) taint manager evicts after the default 300s `tolerationSeconds`.

### DaemonSets

A DaemonSet runs **one pod per *eligible* node** — eligibility = tolerates the
node's taints **and** matches any nodeSelector/affinity. No replica count; it
scales with the cluster. The DS controller auto-tolerates node-*condition* taints
(not-ready, pressure, unschedulable — so daemons survive node trouble and run on
cordoned nodes) but **not** control-plane/custom taints — those you add yourself
(which is why spire-agent needed the explicit toleration to stay on tainted ipc1).

## Choosing a tool when scheduling inputs change

Kubernetes deliberately doesn't auto-re-converge placement (stability over
optimality), so changes need a trigger:
- The change is about a **node** (taint, decommission) → **`drain`**.
- The change is about a **workload** (edited affinity/selector) → **`kubectl
  rollout restart`** that workload (surgical, respects the rollout strategy).
- You want **continuous** re-convergence → the **descheduler** add-on.
- You want the system to auto-evict for a taint → **`NoExecute`**.

## Related

- `scripts/label-nodes.sh` — (re)apply node-class labels (post-reinstall step).
- `config/k3s-server.yaml` — the ipc1 server config holding the control-plane taint.
- `manifests/spire/agent-daemonset.yaml` — spire-agent's blanket toleration.
