# Node Roles & Scheduling

How workloads are placed on this cluster: node roles, the control-plane taint,
hardware-class labels, and the taints/tolerations/affinity model behind them.

## Node inventory

| Node | Role | CPU | `node-class` | Notes |
|------|------|-----|--------------|-------|
| ipc1 | **control-plane (only)** | Pentium G5400T, 2c/4t, 32G | `standard` | API server + SSH bastion; tainted, runs no workloads |
| ipc2 | worker | Pentium G5400T, 2c/4t, 32G | `standard` | |
| ipc3 | worker | Pentium G5400T, 2c/4t, 32G | `standard` | |
| ipc4 | worker | i5-12500T, 6c/12t, 32G | `performance` | |
| ipc5 | worker | i5-12500T, 6c/12t, 32G | `performance` | |
| ipc6 | worker | i5-12500T, 6c/12t, 32G | `performance` | RAM upgraded to 2×16 GiB (was 16G) |

## ipc1 is control-plane-only

ipc1 is a weak 2-core node that is *also* the single API server and the SSH
bastion, so it's dedicated to the control plane and repelled from workloads:

- **Taint:** `node-role.kubernetes.io/control-plane:NoSchedule`.
- **Durable:** set as `node-taint:` in `config/k3s-server.yaml` (the ipc1-only
  server config). k3s applies node-taints at **registration**, so it survives a
  PXE reinstall — a live `kubectl taint` does **not** (a fresh node registers
  untainted).
- **Existing pods were moved off with `kubectl drain`** — `NoSchedule` only
  blocks *new* scheduling, it doesn't evict (see "rechecking" below). The
  workload Deployments rescheduled onto the i5 workers.
- What still runs on ipc1: DaemonSets and the k3s critical addons (coredns,
  traefik) that explicitly **tolerate** the control-plane taint.

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
