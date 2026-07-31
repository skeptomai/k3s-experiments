# Experiment 16 — Pelagos Cgroup Plumbing Verification

This experiment verifies that the full cgroup plumbing chain works end-to-end between k3s, the Pelagos CRI, and metrics-server, which is required for HPA to function. Pelagos issue #327 tracked a regression where `usageCoreNanoSeconds` returned 0 for all CRI-managed containers, silently breaking HPA with `FailedGetResourceMetric`. This experiment is the permanent regression test for that fix (v0.65.28), confirming that each link in the chain — from kubelet passing `cgroup_parent` through the CRI RPC, to Pelagos writing `cgroup_name` to state.json, to kubelet reading accumulating CPU stats from the cgroup filesystem — is intact.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `cgroup-verify` namespace |
| `deployment.yaml` | 3-replica nginx deployment spread one pod per node via `topologySpreadConstraints` |

## Apply

```
kubectl apply -f experiments/16-cgroup-plumbing/namespace.yaml
kubectl apply -f experiments/16-cgroup-plumbing/deployment.yaml
```

Wait for all 3 pods to be Running: `kubectl get pods -n cgroup-verify -o wide`

## Observe

For each pod, verify three links in the chain:

1. **`cgroup_name` is non-null** — SSH to the pod's node and run `sudo pelagos container inspect <container-id>`. The `cgroup_name` field should start with `kubepods/`. This confirms k3s is passing `cgroup_parent` to the CRI and Pelagos is recording it.

2. **cgroup exists in the filesystem** — On the pod's node, check that `/sys/fs/cgroup/kubepods/.../<container-id>` exists. This confirms the container is placed in the correct cgroup hierarchy, not just that the name was recorded.

3. **`usageCoreNanoSeconds` is non-zero and accumulating** — Query the kubelet stats endpoint on the pod's node: `kubectl get --raw /api/v1/nodes/<node>/proxy/stats/summary`. Find the pod by namespace and container name; `usageCoreNanoSeconds` must be non-zero and increasing between successive reads. A value that is always 0 indicates the fallback `/proc/{pid}/stat` path is being used, which produces only instantaneous readings and breaks HPA.

After stats are accumulating, confirm metrics-server picks them up: `kubectl top pod -n cgroup-verify`. All pods should show non-zero CPU usage rather than `<unknown>`.

## Teardown

```
kubectl delete namespace cgroup-verify
```
