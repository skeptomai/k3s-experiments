# Experiment 24 — Envoy mTLS: the sidecar pattern (requires Pelagos #331 fix)

Experiment 23 demonstrated Envoy mTLS in a gateway topology — each proxy in its own pod — because Pelagos left the pod loopback interface (`lo`) down, making the true sidecar pattern impossible. That bug was fixed in Pelagos v0.65.31. This experiment is the payoff: two pods, each containing an application container and an Envoy sidecar co-located on `127.0.0.1`, with mTLS established between sidecars using SPIRE SVIDs. Neither application knows TLS exists.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Namespace `sidecar-demo` plus `ServiceAccount`s for server and client pods |
| `registration-job.yaml` | SPIRE registration job — creates entries for `sidecar-server` and `sidecar-client` SPIFFEIDs |
| `envoy-configs.yaml` | `ConfigMap`s with Envoy config for both sidecars; server terminates mTLS on `:9443`, client originates mTLS from `:15001` |
| `server.yaml` | `Deployment` running `http-echo` + Envoy sidecar, plus a `Service` exposing `:9443` |
| `client.yaml` | `Pod` running `curl` app + Envoy sidecar; app speaks plain HTTP to `127.0.0.1:15001` |

## Apply

Apply in order — SPIRE entries must exist before the pods start:

```
kubectl apply -f experiments/24-envoy-sidecar/namespace.yaml
kubectl apply -f experiments/24-envoy-sidecar/envoy-configs.yaml
kubectl apply -f experiments/24-envoy-sidecar/server.yaml
kubectl apply -f experiments/24-envoy-sidecar/registration-job.yaml
```

Wait for the registration job to complete, then apply the client:

```
kubectl wait -n spire job/spire-register-sidecar --for=condition=complete --timeout=60s && kubectl apply -f experiments/24-envoy-sidecar/client.yaml
```

## Observe

1. Check the client app logs — it should print five successful HTTP responses received over the `localhost → mTLS → localhost` path:

   `kubectl logs -n sidecar-demo sidecar-client -c app`

2. Confirm the Envoy sidecars obtained SVIDs from SPIRE:

   `kubectl logs -n sidecar-demo sidecar-client -c envoy | grep -i svid`

3. Verify the server Envoy is terminating mTLS (look for TLS handshake activity):

   `kubectl logs -n sidecar-demo deploy/sidecar-server -c envoy | grep -i tls`

4. The key contrast with experiment 23: there is no cross-pod proxy-to-proxy Service for each direction. The only cross-pod hop is the mTLS Service `sidecar-server-svc:9443`. The app↔sidecar hops are both over `127.0.0.1` inside each pod — which requires Pelagos v0.65.31+ to work.

## Teardown

`kubectl delete namespace sidecar-demo && kubectl delete -n spire job/spire-register-sidecar`
