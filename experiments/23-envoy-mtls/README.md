# Experiment 23: Transparent mTLS with Envoy and SPIRE

## What you'll observe

- A `backend` pod running a plain HTTP app (`http-echo`) — completely TLS-unaware
- A `driver` pod running `curl` — also completely TLS-unaware
- Two Envoy proxy pods between them that transparently establish mTLS using SPIRE SVIDs
- A plain HTTP request from the driver reaching the backend, having traversed an mTLS hop in the middle that neither end knows about
- Certificate management handled entirely by Envoy via SPIRE's SDS API — no cert files, no app changes

## The key difference from experiment 21

Experiment 21 showed *explicit* mTLS: the application fetched its own SVID and passed it to `openssl s_client`. The app was TLS-aware.

This experiment shows *transparent* mTLS: the app (and the client) speak plain HTTP and have no knowledge of TLS. Envoy proxies handle all certificate operations. This is the model behind service meshes — you add mTLS to existing services without touching their code.

## Architecture — and why it's proxies in separate pods, not sidecars

The textbook Envoy mTLS demo co-locates each Envoy with its app *in the same pod* as a sidecar, and the app talks to its sidecar over `127.0.0.1`. **That does not work on Pelagos** — see "Pelagos compatibility" below. Pelagos shares the pod network namespace correctly but leaves the loopback interface (`lo`) down, so an app cannot reach a sidecar over `127.0.0.1` (or even via the pod's own IP, which the kernel delivers through loopback).

This experiment therefore runs each Envoy as its own pod (a gateway/proxy pattern) and connects everything with Kubernetes Services. Service traffic flows over `eth0` across the CNI bridge — never the loopback — so it is unaffected and works reliably on Pelagos. The "app is TLS-unaware" property is fully preserved — the proxies still terminate and originate TLS and forward plain HTTP to the apps.

```
 driver (curl)                                                         backend (http-echo)
 plain HTTP                                                            plain HTTP
     │                                                                       ▲
     │ http://mtls-client-svc:8080                  http://backend-svc:8080  │
     ▼                                                                       │
 mtls-client (Envoy)                                              mtls-server (Envoy)
 gets SVID from SPIRE                                             gets SVID from SPIRE
 SPIFFE: envoy-client                                            SPIFFE: envoy-server
     │                                                                       ▲
     │   mTLS over https://mtls-server-svc:9443                              │
     └──────────────── SPIFFE SVIDs, mutual auth ───────────────────────────┘
```

Every arrow is a Kubernetes Service (cross-pod networking). No two communicating containers share a pod.

## How Envoy integrates with SPIRE

Envoy's **SDS (Secret Discovery Service)** is a gRPC API for dynamically fetching TLS certificates. SPIRE's agent implements SDS over a Unix socket, so Envoy requests SVIDs directly from the agent — no certificate files on disk.

Each Envoy config references two SDS secrets:
- `spiffe://ipc.local/envoy-server` (or `envoy-client`) — the workload's own cert and private key
- `ROOTCA` — the trust bundle used to verify the peer

Envoy connects to the SPIRE agent socket (mounted via hostPath) and subscribes to these secrets over a streaming gRPC channel. SPIRE pushes the SVID immediately and pushes a fresh one before expiry — Envoy rotates certificates automatically, with no restart.

### Server proxy (`mtls-server`)

Listens on `:9443` with downstream TLS. `require_client_certificate: true` enforces mutual authentication. The validator accepts any peer whose URI SAN starts with `spiffe://ipc.local/` — only workloads in this trust domain may connect. Forwards decrypted plain HTTP to `backend-svc:8080`.

### Client proxy (`mtls-client`)

Listens on `:8080` for plain HTTP. Forwards to `mtls-server-svc:9443` with upstream TLS, presenting the client SVID. Its validator uses an **exact** SAN match — it will only talk to a server presenting `spiffe://ipc.local/envoy-server`. That is SPIFFE-aware authorization at the connection level.

## Pelagos compatibility

### The pod loopback interface (`lo`) is left DOWN

Standard Kubernetes/CRI places every container in a pod into one shared network namespace (created by the pause/sandbox container) **and brings up its loopback interface** (via the CNI `loopback` plugin). Sharing alone is not enough — `lo` must be UP for containers to talk over `127.0.0.1`.

Pelagos (verified v0.65.30) shares the netns correctly but leaves `lo` administratively DOWN. Definitive single-variable reproduction inside a pod netns:

```
# lo DOWN (as Pelagos leaves it):
1: lo: <LOOPBACK> ... qdisc noop state DOWN
probe 127.0.0.1:7777  → FAILS

# after `ip link set lo up`:
1: lo: <LOOPBACK,UP,LOWER_UP> ... qdisc noqueue state UNKNOWN
probe 127.0.0.1:7777  → HTTP/1.1 200 OK
```

Nothing else changes — bringing `lo` up fixes it. With `lo` down, both `127.0.0.1` and connections to the pod's own IP fail (the kernel delivers traffic to a local address via loopback). This breaks any co-located sidecar (service mesh data planes, Vault agent injector, etc.).

Note: `kubectl exec` on Pelagos lands in the *host* network namespace, not the container's, so exec-based `ip addr`/netns checks are misleading — always inspect the container's main process. (The netns sharing was verified by reading `/proc/<workload-pid>/ns/net` from the host: pause + both containers share one inode.)

**Workaround used here:** give each component its own pod and connect via Services. Service traffic uses `eth0`, not loopback, so it is unaffected. Cross-pod networking (including cross-node) works correctly on Pelagos.

This is the same class of CRI gap as the two issues found in experiment 11 — `hostPID` not implemented (Pelagos #299, fixed v0.65.7) and 32-char container IDs (#301, fixed v0.65.8). Filed as [Pelagos #331](https://github.com/pelagos-containers/pelagos/issues/331).

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `envoy-demo` namespace + `envoy-server-sa` / `envoy-client-sa` |
| `registration-job.yaml` | Registers `envoy-server` and `envoy-client` SPIFFE IDs in SPIRE |
| `envoy-configs.yaml` | Server and client Envoy configs as ConfigMaps |
| `backend.yaml` | `http-echo` Deployment + `backend-svc` (plain HTTP app) |
| `server.yaml` | `mtls-server` Envoy proxy Deployment + `mtls-server-svc` (:9443 mTLS) |
| `client.yaml` | `mtls-client` Envoy proxy Deployment + `mtls-client-svc` (:8080 plain) |
| `driver.yaml` | one-shot `curl` pod that drives traffic at `mtls-client-svc` |

## Running manually

```
kubectl apply -f experiments/23-envoy-mtls/namespace.yaml
kubectl apply -f experiments/23-envoy-mtls/registration-job.yaml
kubectl wait --for=condition=complete job/spire-register-envoy -n spire --timeout=60s
kubectl apply -f experiments/23-envoy-mtls/envoy-configs.yaml
kubectl apply -f experiments/23-envoy-mtls/backend.yaml
kubectl apply -f experiments/23-envoy-mtls/server.yaml
kubectl apply -f experiments/23-envoy-mtls/client.yaml
kubectl rollout status deployment/backend     -n envoy-demo
kubectl rollout status deployment/mtls-server  -n envoy-demo
kubectl rollout status deployment/mtls-client  -n envoy-demo
kubectl apply -f experiments/23-envoy-mtls/driver.yaml
kubectl logs driver -n envoy-demo --follow
```

## Expected output (driver logs)

```
Driver sends plain HTTP to the client proxy. It has no idea TLS is involved.
--- Request 1 ---
HTTP/1.1 200 OK
Hello from backend! (plain HTTP; mTLS handled by Envoy proxies)
...
=== Done: 5 plain-HTTP requests traversed an mTLS hop between Envoy proxies ===
```

## Verifying the mTLS

Confirm real TLS handshakes and that peer verification passed (server proxy admin API):

```
PODIP=$(kubectl get pod -n envoy-demo -l app=mtls-server -o jsonpath='{.items[0].status.podIP}')
kubectl run vchk --image=curlimages/curl:8.6.0 -n envoy-demo --restart=Never --rm -i -- \
  curl -s http://$PODIP:9901/stats | grep -E 'ssl.handshake|fail_verify'
```

Confirm a workload **without** an SVID is rejected (mutual auth enforced):

```
kubectl run noauth --image=curlimages/curl:8.6.0 -n envoy-demo --restart=Never --rm -i -- \
  sh -c 'curl -sk --max-time 8 https://mtls-server-svc:9443/ ; echo exit=$?'
# curl exits 55 — the server closes the connection because no client certificate was presented.
```

## Relationship to experiment 21

| | Exp 21 (openssl) | Exp 23 (Envoy) |
|---|---|---|
| App TLS awareness | Explicit — app fetched SVID, called openssl | None — app speaks plain HTTP |
| Certificate rotation | Manual (init container, one-time fetch) | Automatic (Envoy subscribes to SPIRE SDS) |
| Peer authorization | openssl verifies chain only | Envoy validates SPIFFE URI SAN exactly |
| Topology | Two single-container pods | Two apps + two proxy pods, Services between |
| Production model | Educational demo | Service-mesh data-plane pattern (gateway form; sidecar form blocked by Pelagos #331) |
