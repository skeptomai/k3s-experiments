# kube-vip — HA Control-Plane VIP

Gives the 3-node control plane (ipc1-3, see `ipc1-3-control-plane-ha-runbook.md`) a
single **floating API endpoint** — `192.168.88.58` (DNS `k8s-api.home.skeptomai.com`) —
so a control-plane node failure doesn't break API access for LAN clients and tenant
nodes. Deployed **2026-06-28**.

> **Unblocked by pelagos v0.65.40.** kube-vip runs as a `hostNetwork` pod, and before
> v0.65.40 every hostNetwork pod crash-looped ~1×/sec — `PodSandboxStatus` reported
> `network=POD` for hostNetwork sandboxes, so the kubelet recreated the sandbox every
> sync (pelagos #410 / PR #411). The cluster must be on **≥ v0.65.40** for kube-vip to
> be stable.

## What it is

- **kube-vip v1.2.1**, **ARP (layer-2)** mode, **control-plane only** (`svc_enable=false`
  — Service `LoadBalancer`s are MetalLB's job, not this).
- A **DaemonSet on ipc1-3** (`nodeSelector: node-role.kubernetes.io/control-plane`,
  tolerates the `control-plane` + `slow` taints), **leader-elected** (lease
  `plndr-cp-lock`). Exactly one node advertises the VIP at a time via gratuitous ARP on
  `enp2s0`.

## The VIP — prerequisites (all done)

| Piece | Where | Why |
|---|---|---|
| `192.168.88.58` | the VIP | floating control-plane API address |
| DNS `k8s-api.home.skeptomai.com → .58` | MikroTik static DNS | name for the endpoint |
| `.58` excluded from DHCP pool | MikroTik pool split `.10-.57,.59-.254` | so DHCP never hands it out |
| `tls-san: [192.168.88.58, k8s-api.home.skeptomai.com]` | `config/k3s-server.yaml` + `config/k3s-server-join.yaml` | so the apiserver serving cert validates for the VIP |

The MikroTik bits are out-of-band (not in this repo); the `tls-san` lines are in the
server configs and deploy via `install-pelagos.sh`.

## Files

- `manifests/kube-vip/rbac.yaml` — ServiceAccount + ClusterRole/Binding
- `manifests/kube-vip/daemonset.yaml` — the kube-vip DaemonSet
- `manifests/kube-vip/kustomization.yaml`
- `clusters/ipc/kube-vip.yaml` — Flux Kustomization (Flux owns it: `flux get kustomization kube-vip`)

## Reaching the API

Two distinct paths — don't conflate them:

- **In-cluster (workers → API): already HA, independent of kube-vip.** k3s's embedded
  client-side load balancer on each agent fails over across all three servers. kube-vip
  is **not** involved here.
- **External clients (kubeconfig):** use the dual-context setup on omen:

| Context | Server | HA? | Reachable |
|---|---|---|---|
| `default` (current) | `https://ipc1:6443` (tailnet `100.75.70.89`) | ❌ pinned to ipc1 | anywhere (Tailscale) |
| `ipc-vip` | `https://192.168.88.58:6443` (the VIP) | ✅ floats ipc1↔3 | **LAN only** (`.58` is not on the tailnet) |

`kubectl --context ipc-vip ...` when on the home LAN for HA; `default` stays the
everywhere-reachable (but not-HA) tailnet path. The VIP cluster reuses the same cluster
CA (the VIP's cert is signed by it, with `.58` in the SAN).

## Failover behavior — and one caveat

- **Pod churn:** restarting/deleting a kube-vip pod causes **no API outage** — the VIP
  stays on a healthy node (verified).
- **Real node-down** (node powers off → kube-vip pod dies): the lease (5s) expires and
  the VIP floats to a live node. This is the case kube-vip primarily protects against.
- **⚠️ Caveat — apiserver-only failure on the leader.** kube-vip floats on
  **leader-election**, not apiserver health. If a control-plane node's *apiserver* dies
  while the node and the kube-vip pod keep running, kube-vip keeps the lease (it renews
  via a live peer through the in-cluster API) and the VIP **sticks to that node** —
  pointing at a dead apiserver. **This is more likely on pelagos** than on other
  runtimes: pelagos re-adopts running pods across a `pelagos-cri`/`k3s` restart (#336),
  so a routine `systemctl restart k3s` (e.g. during an upgrade) drops the apiserver
  briefly while keeping kube-vip alive.
  - **Mitigation:** enable kube-vip's apiserver health-check so the leader steps down
    when its local API is unhealthy. *(Status: see "Health check" below.)*

## Health check

<!-- KUBEVIP-HEALTHCHECK-STATUS -->
(To be filled in when the apiserver health-check is enabled — closes the caveat above.)

## Re-deploying / verifying

```bash
kubectl apply -k manifests/kube-vip                 # or let Flux reconcile
kubectl -n kube-system get pods -l app.kubernetes.io/name=kube-vip-ds -o wide   # 3 pods, 0 restarts
kubectl --context ipc-vip get --raw /healthz        # "ok" via the VIP
for n in ipc1 ipc2 ipc3; do ssh $n "ip -4 addr show enp2s0 | grep -q 192.168.88.58 && echo $n holds VIP"; done
```
