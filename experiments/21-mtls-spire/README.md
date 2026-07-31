# Experiment 21 — mTLS with SPIRE SVIDs

This experiment demonstrates mutual TLS authentication between two Kubernetes workloads using X.509 SVIDs issued by SPIRE — no secrets, no pre-distributed certificates. Experiment 11 showed that a workload can obtain an SVID from the Workload API; this experiment shows what to do with one: present it as a TLS client certificate to authenticate to another service. Both sides derive their identity purely from SPIRE attestation, proving that the zero-secret certificate distribution model works end-to-end across a real TLS handshake.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `mtls-demo` namespace and two ServiceAccounts (`mtls-server-sa`, `mtls-client-sa`) used as SPIRE attestation selectors |
| `registration-job.yaml` | Job (runs in the `spire` namespace) that registers `spiffe://ipc.local/mtls-server` and `spiffe://ipc.local/mtls-client` entries in the SPIRE server |
| `server.yaml` | Deployment running an `openssl s_server` that requires a client certificate (`-Verify 1`); an init container fetches the SVID via the Workload API before the server starts |
| `client.yaml` | Pod that fetches its own SVID, connects to the server presenting it as a client cert, and prints both sides' SPIFFE IDs from the TLS handshake |

## Apply

Apply in order — the registration job must run before the server and client pods start, so the SPIRE entries exist when the Workload API is first contacted.

```
kubectl apply -f experiments/21-mtls-spire/namespace.yaml
kubectl apply -f experiments/21-mtls-spire/registration-job.yaml
kubectl apply -f experiments/21-mtls-spire/server.yaml
kubectl apply -f experiments/21-mtls-spire/client.yaml
```

Wait for the registration job to complete before the client pod runs:

```
kubectl wait -n spire job/spire-register-mtls --for=condition=complete --timeout=120s
```

## Observe

1. Check that the registration job succeeded and both entries are listed:

   ```
   kubectl logs -n spire job/spire-register-mtls
   ```

2. Watch the server start and print its SPIFFE ID:

   ```
   kubectl logs -n mtls-demo deploy/mtls-server -c fetch-svid
   kubectl logs -n mtls-demo deploy/mtls-server -c server
   ```

   The server logs show the SAN `URI:spiffe://ipc.local/mtls-server` and confirm it is listening on `:8443` with client cert verification enabled.

3. Watch the client complete the handshake:

   ```
   kubectl logs -n mtls-demo mtls-client -c client
   ```

   A successful run prints `Verify return code: 0 (ok)` and extracts the server's SPIFFE ID (`URI:spiffe://ipc.local/mtls-server`) from the peer certificate. Both workloads authenticated each other using only their SPIRE-issued SVIDs — no secrets were deployed.

## Teardown

```
kubectl delete namespace mtls-demo && kubectl delete -n spire job/spire-register-mtls
```
