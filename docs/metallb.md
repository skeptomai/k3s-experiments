# MetalLB — LoadBalancer for bridge-lan

Provides real `LoadBalancer` Service IPs on the LAN via **L2 (ARP)** mode, replacing
k3s's built-in ServiceLB/Klipper. Pool **`192.168.88.240–.250`**. Deployed
**2026-06-28**. It's the prerequisite for exposing Kamaji tenant control planes (each
gets its own LB IP) and gives any Service a proper external IP.

> **Requires pelagos ≥ v0.65.40.** MetalLB's **speaker is a hostNetwork + `NET_RAW`
> pod** — the exact profile that crash-looped before the hostNetwork sandbox-status fix
> (#410 / PR #411). On older pelagos the speaker would restart ~1×/sec. Verified clean
> on v0.65.40 (0 restarts).

## What it is

- **MetalLB v0.16.0**, **L2 (ARP)** mode.
- **controller** (Deployment) — allocates IPs from the pool.
- **speaker** (DaemonSet, hostNetwork + `NET_RAW`) — the elected speaker answers ARP for
  each assigned IP. Speakers run on **ipc4-6 only** — they don't tolerate the `slow`
  taint on the control-plane nodes, which is fine since LB-backed workloads are
  worker-hosted. (To announce from ipc1-3 too, add a `slow` toleration to the speaker
  via a kustomize patch.)
- **`lan-pool`** (`IPAddressPool`): `192.168.88.240-192.168.88.250` · **`lan-l2`**
  (`L2Advertisement`) advertises it.

## IP pool / DHCP

`.240-.254` is carved out of the MikroTik DHCP pool (shrunk to
`192.168.88.10-.57,.59-.239`) so MetalLB's addresses are never handed out dynamically.
The pool uses `.240-.250`; `.251-.254` are spare. (`.58` remains separately reserved for
the kube-vip control-plane VIP — see `kube-vip.md`.)

## ServiceLB replaced (full switch)

k3s ServiceLB (Klipper) is **disabled** via `disable: [local-storage, servicelb]` in the
server configs (`config/k3s-server.yaml` + `config/k3s-server-join.yaml`), applied with a
rolling restart of ipc1-3 (etcd quorum preserved). The `svclb-traefik` DaemonSet was
removed and **Traefik migrated from the node IPs (.55/.56/.57) to `192.168.88.240`**.
Impact was nil — there were **0 Ingress resources** and **no DNS** pointed at the old
Traefik IPs. (This also retires the old "svclb-traefik control-plane toleration" caveat —
there's no svclb DaemonSet anymore.)

## Files

- `manifests/metallb/metallb-native.yaml` — vendored MetalLB v0.16.0 install (+ `kustomization.yaml`)
- `manifests/metallb-config/pool.yaml` — `IPAddressPool` + `L2Advertisement` (+ `kustomization.yaml`)
- `clusters/ipc/metallb.yaml` — Flux Kustomization (install; `wait: true`)
- `clusters/ipc/metallb-config.yaml` — Flux Kustomization (pool; `dependsOn: metallb` so the
  CRDs/webhook exist before the CRs are applied)

## Usage

```yaml
# A Service of type LoadBalancer gets the next free IP from .240-.250:
apiVersion: v1
kind: Service
metadata:
  name: my-svc
  # Pin a specific IP (optional):
  annotations:
    metallb.io/loadBalancerIPs: 192.168.88.245
spec:
  type: LoadBalancer
  ...
```

L2 mode only **announces an IP once the Service has a ready endpoint** — a `LoadBalancer`
with no ready pods shows an EXTERNAL-IP but won't answer ARP until a backend is up (normal).

## Images / registry mirror

`quay.io/metallb/{controller,speaker}:v0.16.0`. **quay.io is not in the cluster's registry
mirror** (`registries.toml` mirrors docker.io / registry.k8s.io / ghcr.io / public.ecr.aws),
so these pull directly from quay.io rather than the LAN cache. Fine, just not cached.

## Verify

```bash
kubectl -n metallb-system get pods                       # controller + 3 speakers, 0 restarts
kubectl -n metallb-system get ipaddresspool,l2advertisement
kubectl get svc -A | grep LoadBalancer                   # EXTERNAL-IPs in .240-.250
# end-to-end:
kubectl create deploy t --image=public.ecr.aws/docker/library/nginx:alpine
kubectl expose deploy t --type=LoadBalancer --port=80
curl http://<assigned-ip>/                               # 200 once the pod is ready
kubectl delete svc t deploy t
```
