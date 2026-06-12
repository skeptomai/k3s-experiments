# Experiment 24: Envoy mTLS — the sidecar pattern (enabled by Pelagos #331)

## What you'll observe

- A **single pod** containing an application *and* its Envoy proxy as a co-located sidecar
- The app speaks plain HTTP to its sidecar over the **pod loopback** (`127.0.0.1`)
- The sidecars establish mTLS between pods using SPIRE SVIDs
- Two apps (an `http-echo` server and a `curl` client) that are completely TLS-unaware, connected by a `localhost → mTLS → localhost` path

This is the canonical service-mesh data-plane topology (Istio/Linkerd/Consul all work this way). It is the form experiment 23 *wanted* to use but could not.

## Why this needed a Pelagos fix

Experiment 23 documented that Pelagos left the pod's loopback interface (`lo`) **down**, so a container could not reach a co-located sidecar over `127.0.0.1`. That broke the sidecar pattern, and exp 23 had to fall back to a gateway form (each proxy in its own pod, connected by Services).

That bug was filed as [Pelagos #331](https://github.com/pelagos-containers/pelagos/issues/331) and fixed in **v0.65.31** ("pod loopback UP + exec joins container NET/UTS/IPC namespaces", PR #333, which also fixed the exec issue #332). With `lo` now up, the localhost hop works and the true sidecar pattern is possible. This experiment is the payoff.

## Architecture

```
┌─── sidecar-client pod ──────────────┐        ┌─── sidecar-server pod ──────────────┐
│                                      │        │                                      │
│  app (curl)                          │        │                          app (http-echo)
│   │ plain HTTP                       │        │              plain HTTP ▲            │
│   │ http://127.0.0.1:15001           │        │     http://127.0.0.1:8080│           │
│   ▼     (pod loopback — needs #331)  │        │  (pod loopback — needs #331)         │
│  Envoy sidecar  ──── mTLS ───────────┼────────┼──►  Envoy sidecar  ──────┘           │
│  SPIFFE: sidecar-client              │        │  SPIFFE: sidecar-server              │
│  (SVID from SPIRE via SDS)           │        │  (SVID from SPIRE via SDS)           │
└──────────────────────────────────────┘        └──────────────────────────────────────┘
                     │                                          ▲
                     └────────── sidecar-server-svc:9443 ───────┘
                                 (cross-pod Service, mTLS)
```

The only network hop that crosses pods is the mTLS one (a Service). Every app↔sidecar hop is over `127.0.0.1` inside one pod.

## Contrast with experiment 23

| | Exp 23 (gateway form) | Exp 24 (sidecar form) |
|---|---|---|
| Topology | 4 pods: backend, server-proxy, client-proxy, driver | 2 pods: each = app + Envoy sidecar |
| App ↔ proxy | cross-pod Service (uses `eth0`) | co-located, over `127.0.0.1` |
| Why | worked around Pelagos #331 (loopback down) | requires the #331 fix (loopback up) |
| Pelagos | any version | **v0.65.31+** |

Everything about the mTLS itself — SPIRE SDS integration, automatic cert rotation, SPIFFE SAN authorization — is identical to exp 23. The difference is purely topological: the proxy now lives beside the app.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `sidecar-demo` namespace + `sidecar-server-sa` / `sidecar-client-sa` |
| `registration-job.yaml` | Registers `sidecar-server` and `sidecar-client` SPIFFE IDs |
| `envoy-configs.yaml` | Server and client sidecar Envoy configs (note the `127.0.0.1` hops) |
| `server.yaml` | `sidecar-server` Deployment: `http-echo` + Envoy sidecar, `sidecar-server-svc` |
| `client.yaml` | `sidecar-client` Pod: `curl` app + Envoy sidecar |

## Running manually

```
kubectl apply -f experiments/24-envoy-sidecar/namespace.yaml
kubectl apply -f experiments/24-envoy-sidecar/registration-job.yaml
kubectl wait --for=condition=complete job/spire-register-sidecar -n spire --timeout=60s
kubectl apply -f experiments/24-envoy-sidecar/envoy-configs.yaml
kubectl apply -f experiments/24-envoy-sidecar/server.yaml
kubectl rollout status deployment/sidecar-server -n sidecar-demo
kubectl apply -f experiments/24-envoy-sidecar/client.yaml
kubectl logs sidecar-client -n sidecar-demo -c app --follow
```

## Expected output (client app logs)

```
App talks plain HTTP to its sidecar at 127.0.0.1:15001 — over the pod loopback.
--- Request 1 ---
HTTP/1.1 200 OK
Hello from the app! (plain HTTP over localhost; sidecar does mTLS)
...
=== Done: app reached the backend over a localhost->mTLS->localhost path ===
```

Note: the client pod stays `Running` rather than reaching `Succeeded` — the app container exits but the Envoy sidecar keeps running. That is normal for sidecar pods.

## Verifying

The server sidecar's admin API confirms both the mTLS hop and the localhost hop:

```
PODIP=$(kubectl get pod -n sidecar-demo -l app=sidecar-server -o jsonpath='{.items[0].status.podIP}')
kubectl run vchk --image=curlimages/curl:8.6.0 -n sidecar-demo --restart=Never --rm -i -- \
  curl -s http://$PODIP:9901/stats | grep -E 'ssl.handshake|fail_verify|local_app.upstream_(rq_200|cx_connect_fail)'
```

Expect non-zero `ssl.handshake`, zero `fail_verify_*`, and `cluster.local_app.upstream_cx_connect_fail: 0` — the last proves the sidecar reaches the app over `127.0.0.1` (the hop that failed before Pelagos v0.65.31).
