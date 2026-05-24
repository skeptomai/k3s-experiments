# Load Balancing Techniques in Kubernetes

## The spectrum

| Technique | Where | Overhead | L7-aware |
|-----------|-------|----------|----------|
| eBPF (Cilium) | kernel | lowest — direct map lookup | no |
| IPVS | kernel | low — hash table | no |
| iptables (kube-proxy default) | kernel | low — linear chain traversal | no |
| Userspace proxy (Traefik, Envoy) | userspace | higher — kernel/userspace boundary crossing | yes |

## Why kernel-space is faster

iptables, IPVS, and eBPF all run inside the kernel's netfilter hooks. The packet
is rewritten before it ever reaches a userspace process — no context switch, no
data copy, no process scheduling. Overhead is nanoseconds.

A userspace proxy like Traefik crosses the kernel/userspace boundary twice per
request: once inbound, once outbound. The kernel manages TCP state on both
sides and copies data between them. That's microseconds to low milliseconds of
added latency before Traefik does any actual work.

## Why you accept the userspace overhead

Kernel-space balancing is L4 — it sees packets and IPs, nothing more. You
cannot read an HTTP header, match a URL path, or inspect a TLS SNI in an
iptables rule. Traefik being a real process is what makes these possible:

- **Host/path routing** — read the HTTP Host header and route accordingly
- **TLS termination** — accept HTTPS from the client, forward plain HTTP to pods
- **Health checking** — actively probe backends, stop sending to pods returning 500s
- **Retries** — transparently retry a failed request against a different pod
- **Circuit breaking** — stop sending to a backend entirely while it recovers
- **Connection pooling** — maintain persistent upstream connections to pods
- **Observability** — per-request metrics, status codes, latency, which backend handled what

## kube-proxy (iptables) — how it actually works

kube-proxy watches the Endpoints object for each Service. When pods come or go,
it reprograms iptables rules in the kernel, then steps out of the way entirely.
No process is in the hot path for individual requests.

The balancing is implemented as a chain of probability rules evaluated top to
bottom. For 3 pods:

```
rule 1: 33% chance → DNAT to pod A
rule 2: 50% chance → DNAT to pod B   (50% of remaining 67% ≈ 33%)
rule 3: catch-all  → DNAT to pod C   (remaining ≈ 33%)
```

DNAT (destination NAT) rewrites the packet's destination IP from the Service's
cluster IP to the selected pod's real IP. The kernel forwards it from there.

This is stateless and has no feedback — a saturated pod gets the same traffic
as an idle one. Acceptable for most workloads because pods are homogeneous and
requests are short-lived.

## Traefik — how it actually works

Traefik queries the Endpoints object directly (bypassing kube-proxy entirely)
and maintains its own view of available backends. Every request flows through
Traefik as a reverse proxy. The routing decision is made at the HTTP layer.

## When the overhead difference matters

Almost never in practice. A database query or remote API call adds tens to
hundreds of milliseconds. The routing hop adds sub-millisecond overhead. The
difference is only relevant for extremely high-frequency, low-latency internal
service communication — financial systems, HFT, that kind of workload.

For this cluster, Traefik's overhead is invisible and the L7 capabilities are
worth it.
