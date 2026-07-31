# Experiment 11 — SPIRE Node and Workload Attestation

SPIRE (SPIFFE Runtime Environment) solves a fundamental bootstrapping problem: how does a workload prove its identity to get a secret, without being given a secret first? This experiment shows SPIRE establishing cryptographic workload identity via attestation — the SPIRE Agent proves to the Server that it runs on a legitimate cluster node (using Kubernetes Projected Service Account Tokens), and the Agent proves to each pod which registration entry matches it (by mapping the calling process's PID to its pod via the CRI). The result is an X.509 SVID issued to the workload with its SPIFFE ID baked in — no secrets injected at deploy time.

## Files

| File | Purpose |
|------|---------|
| `demo-namespace.yaml` | Creates the `spire-demo` namespace and `demo-sa` ServiceAccount that workload attestation selects on |
| `demo-registration-rbac.yaml` | ServiceAccount, Role, and RoleBinding that allow the registration job to `kubectl exec` into the SPIRE Server pod |
| `demo-registration-job.yaml` | One-shot Job that creates a node alias entry (all `k8s_psat` agents in cluster `ipc`) and a workload entry mapping `spire-demo/demo-sa` to `spiffe://ipc.local/demo-app` |
| `demo-workload.yaml` | Pod that fetches its X.509 SVID from the Workload API socket and prints the embedded SPIFFE ID and certificate details |

## Prerequisites

SPIRE must already be deployed in the `spire` namespace (managed by Flux from `manifests/spire/`). Verify with:

```
kubectl get pods -n spire
```

Both `spire-server-0` and all `spire-agent-*` pods must be Running before proceeding.

## Apply

Apply in order — the namespace and RBAC must exist before the Job, and the registration entries must exist before the workload pod is created:

```
kubectl apply -f experiments/11-spire/demo-namespace.yaml
kubectl apply -f experiments/11-spire/demo-registration-rbac.yaml
kubectl apply -f experiments/11-spire/demo-registration-job.yaml
```

Wait for the registration job to complete:

```
kubectl wait -n spire --for=condition=complete job/spire-register-demo --timeout=60s
```

Then deploy the workload:

```
kubectl apply -f experiments/11-spire/demo-workload.yaml
```

## Observe

Watch the workload pod start up — it has an init container that waits for the SPIRE Agent socket, then the main container fetches its SVID:

```
kubectl logs -n spire-demo demo-workload -c demo -f
```

You should see the SPIFFE ID printed from the certificate's Subject Alternative Name:

```
URI:spiffe://ipc.local/demo-app
```

And certificate details confirming the issuer is the SPIRE Server acting as the `ipc.local` CA.

To inspect the registration entries that were created:

```
kubectl exec -n spire pod/spire-server-0 -- /opt/spire/bin/spire-server entry show
```

To see agent attestation status (one entry per node):

```
kubectl exec -n spire pod/spire-server-0 -- /opt/spire/bin/spire-server agent show
```

## Teardown

```
kubectl delete namespace spire-demo && kubectl delete -f experiments/11-spire/demo-registration-rbac.yaml
```

The registration job auto-deletes after 600 seconds (`ttlSecondsAfterFinished`). Registration entries in the SPIRE Server persist until explicitly removed via `spire-server entry delete`.
