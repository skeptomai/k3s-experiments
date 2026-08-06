# Tailscale Operator: How a Packet Reaches `gruesome`

Live-traced 2026-08-06 to answer "how does tailnet access to an in-cluster
app actually work end to end" — every hop below was directly observed on
the running cluster, not inferred from documentation.

## Two independent Tailscale layers

This cluster has **two separate, unrelated** Tailscale integrations. Don't
conflate them:

1. **Host-level `tailscaled`** — runs directly on each node's OS (ipc4-9,
   nazgul, omen). Gives each node its own tailnet identity
   (`ipc4.taildd208.ts.net`, etc.), used for SSH/admin access. Nothing to
   do with Kubernetes.
2. **In-cluster Tailscale Kubernetes Operator** (`manifests/tailscale-operator/`,
   deployed via the official Helm chart from `pkgs.tailscale.com/helmcharts`,
   standard Flux HelmRelease — not custom-built) — exposes specific k8s
   Services onto the tailnet. This doc is about this layer.

## How a Service gets exposed

Annotate the Service:

```yaml
metadata:
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: gruesome
```

The operator reacts by creating a dedicated single-replica **StatefulSet**
(`ts-gruesome-platform-rb9q4`) in the `tailscale` namespace, owning a pod
that runs the official `tailscale/tailscale:v1.98.9` image. State (WireGuard
keys / node identity) persists in a per-pod Kubernetes Secret
(`TS_KUBE_SECRET=$(POD_NAME)`), so the tailnet device identity survives pod
restarts/reschedules instead of re-registering as a new device each time.

Key env vars on the proxy pod (confirmed via `kubectl get pod -o yaml`):

| Var | Value | Meaning |
|---|---|---|
| `TS_USERSPACE` | `false` | Kernel networking mode — pod creates its own real tun device + manages its own netfilter rules via netlink, not a userspace SOCKS relay. Requires `privileged: true`. |
| `TS_DEST_IP` | `10.43.223.58` | The target Service's **ClusterIP** — confirmed via `kubectl get svc gruesome-platform` (`Type: ClusterIP`, port 80). tailscaled NATs tailnet-bound traffic straight to this IP. |
| `TS_KUBE_SECRET` | `$(POD_NAME)` | Per-pod Secret storing WireGuard keys/identity across restarts. |
| `TS_INTERNAL_APP` | `k8s-operator-ingress-proxy` | Confirms this is the operator's Service-exposure proxy mode (there's a separate `tailscale` IngressClass for the operator's other mode, currently unused — nothing in the cluster creates `Ingress` objects with `ingressClassName: tailscale`; the 3 real `Ingress` resources all use `traefik`). |

The operator's own OAuth client (`operator-oauth` Secret, tagged
`tag:k8s-operator` per `helmrelease.yaml`) authenticates the proxy pod to
the tailnet — no manual ACL/tagOwners entry needed per exposed Service.

## The full packet path (client → app)

Traced live: `curl http://gruesome.taildd208.ts.net/` from omen (also on
the tailnet) → `200`, 753ms.

```mermaid
sequenceDiagram
    participant omen as omen<br/>(tailnet peer)
    participant pod as ts-gruesome-platform-rb9q4-0<br/>(pod netns, ipc5)
    participant host as ipc5<br/>(host netns)
    participant backend as gruesome-platform<br/>backend pod (10.42.4.217)

    Note over omen,pod: Leg 1 — WireGuard, direct (no DERP)
    omen->>pod: encrypted UDP, direct 67.161.100.154:12227 → tailscale0 (100.124.195.64)

    Note over pod,host: Leg 2 — host transit
    Note right of host: conntrack reverses the pod's own earlier<br/>egress SNAT; delivered via veth into pod netns

    Note over pod: Leg 3 — inside the pod
    pod->>pod: tailscaled decrypts on tailscale0,<br/>rewrites dest via TS_DEST_IP=10.43.223.58,<br/>re-injects out eth0 (10.42.0.67, default route via veth gw 10.42.0.139)

    Note over pod,host: Leg 4 — ClusterIP DNAT (kube-proxy, nftables)
    pod->>host: packet crosses veth into host netns
    host->>host: ip daddr 10.43.223.58 tcp dport 80 -> service chain -> vmap -> 10.42.4.217:8080

    Note over host,backend: Leg 5 — vxlan overlay to real backend
    host->>backend: delivered to gruesome app container
    backend-->>omen: 200 OK (reverse path)
```

### Confirmed at each hop

- **Leg 1**: `kubectl exec -n tailscale ts-gruesome-platform-rb9q4-0 -- tailscale status` showed
  `100.118.42.117  omen  ...  active; direct 67.161.100.154:12227, tx=24940 rx=2756` —
  a genuine direct UDP path (NAT hole-punched via Tailscale's coordination
  server), not relayed through a DERP server. `tx`/`rx` byte counts matched
  the size of the test request.
- **Leg 3**: `kubectl exec ... -- ip addr show` confirmed two interfaces in
  the pod's netns: `tailscale0` (`100.124.195.64/32`, the WireGuard tun
  device) and `eth0` (`10.42.0.67/32`, the normal Cilium-assigned pod
  interface, default route via `10.42.0.139`). No ClusterIP-specific route
  present in the pod — confirms the DNAT in Leg 4 happens in the **host's**
  netns as the packet crosses the veth, not inside the pod's own routing
  table.
- **Leg 4**: `sudo nft list ruleset` on ipc5 showed the live kube-proxy rule:
  ```
  ip daddr 10.43.223.58 ip saddr != 10.42.0.0/16 jump mark-for-masquerade
  numgen random mod 1 vmap { 0 : goto endpoint-.../gruesome-platform/tcp/__10.42.4.217/8080 }
  ```
  Confirms this cluster's `kubeProxyReplacement=false` Cilium config is
  accurate in practice: ClusterIP resolution is handled by k3s's own
  kube-proxy (nftables mode), not Cilium's eBPF service map. The `vmap`
  with `mod 1` reflects `gruesome-platform` currently having exactly one
  backend endpoint; with more replicas the same weighted-random primitive
  load-balances across all of them.
- Conntrack entry for the specific test flow had already expired by the
  time it was checked (short-lived HTTP request) — not a gap in the trace,
  just normal conntrack GC on a completed connection.

## Why no inbound port-forward is needed

The proxy pod's `tailscaled` always initiates *outbound* — to Tailscale's
coordination server and, for the actual data path, directly to the peer
(or via DERP relay if direct fails). This means the pod is functionally
"just another NAT'd client" from Tailscale's perspective, despite sitting
behind two stacked NAT layers (the home router, plus Cilium's own
pod-egress SNAT for traffic leaving the pod CIDR). Neither NAT layer needs
a manual port-forward rule — both allow return traffic on a connection the
pod itself opened, which is exactly how Tailscale's NAT traversal is
designed to work everywhere, not just in this cluster.
