# Experiment 23 — Transparent mTLS with Envoy and SPIRE

Mutual TLS is most useful when applications don't have to implement it themselves. This experiment shows Envoy acting as a transparent mTLS gateway between a plain-HTTP client (`curl`) and a plain-HTTP server (`http-echo`) — neither endpoint knows TLS exists. Certificate management is handled entirely by Envoy via SPIRE's SDS API, with SVIDs rotated automatically. This is the foundational model behind service meshes.

> **Note:** This experiment uses a gateway form (each Envoy in its own pod) because it was originally built on Pelagos v0.65.30, where a pod loopback bug ([#331](https://github.com/pelagos-containers/pelagos/issues/331)) made the co-located sidecar pattern impossible. That bug was fixed in v0.65.31. The true sidecar form is shown in [experiment 24](../24-envoy-sidecar/). This experiment is kept as-is: the gateway pattern is valid in its own right, and it documents the bug hunt that led to the fix.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `envoy-demo` namespace plus `envoy-server-sa` and `envoy-client-sa` ServiceAccounts |
| `registration-job.yaml` | SPIRE Job (runs in `spire` namespace) that registers `spiffe://ipc.local/envoy-server` and `spiffe://ipc.local/envoy-client` entries |
| `envoy-configs.yaml` | ConfigMaps holding Envoy config for the server proxy (terminates mTLS, forwards plain HTTP) and the client proxy (originates mTLS, accepts plain HTTP) |
| `backend.yaml` | `http-echo` Deployment and Service — a plain-HTTP app with no TLS awareness |
| `server.yaml` | `mtls-server` Deployment: Envoy proxy that terminates mTLS from the client proxy and forwards plain HTTP to the backend; exposes `mtls-server-svc:9443` |
| `client.yaml` | `mtls-client` Deployment: Envoy proxy that accepts plain HTTP from the driver and originates mTLS toward the server proxy; exposes `mtls-client-svc:8080` |
| `driver.yaml` | One-shot Pod that sends five plain-HTTP requests to the client proxy and prints the results |

## Apply

Register SPIRE entries first (the Envoy pods wait for the SPIRE socket but won't get SVIDs until entries exist):

```
kubectl apply -f experiments/23-envoy-mtls/namespace.yaml
kubectl apply -f experiments/23-envoy-mtls/registration-job.yaml
```

Wait for the registration job to complete, then apply the rest:

```
kubectl apply -f experiments/23-envoy-mtls/
```

## Observe

Watch all pods come up in `envoy-demo`:

```
kubectl get pods -n envoy-demo -w
```

Once the driver pod completes, read its output — it shows five plain-HTTP requests that each traversed an mTLS hop:

```
kubectl logs -n envoy-demo driver
```

You should see `HTTP/1.1 200 OK` responses and the `http-echo` body confirming the backend received plain HTTP. To confirm the mTLS hop happened, check the server-side Envoy logs for TLS handshake activity:

```
kubectl logs -n envoy-demo -l app=mtls-server
```

Look for `TLS handshake` lines and the peer SVID (`spiffe://ipc.local/envoy-client`) logged during connection setup.

To verify SPIRE issued SVIDs to both proxies, check the registration job output:

```
kubectl logs -n spire -l job-name=spire-register-envoy
```

## Teardown

```
kubectl delete namespace envoy-demo
```

The registration job runs in the `spire` namespace and cleans itself up after 600 seconds (`ttlSecondsAfterFinished`). To remove the SPIRE entries immediately, exec into `spire-server-0` and delete them by SPIFFE ID.
