# Experiment 17 — Container Memory Stats Verification

Pelagos issue [#328](https://github.com/pelagos-containers/pelagos/issues/328) caused `kubectl top pod` to always report ~1Mi of memory per container, regardless of actual workload size. The bug was that `ContainerStats` read `VmRSS` from the Pelagos launcher PID (~1.25MB) rather than the cgroup total, so every container looked nearly idle. Fixed in v0.65.30 by reading `memory.current` from the cgroupv2 hierarchy directly. This experiment deploys a pod that allocates ~20MB at startup and confirms that reported memory reflects the actual workload.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `memstats-demo` namespace |
| `deployment.yaml` | busybox pod that allocates ~20MB at startup and holds it for observation |

## Apply

```
kubectl apply -f experiments/17-memory-stats/namespace.yaml -f experiments/17-memory-stats/deployment.yaml
```

Wait for the pod to reach Running state: `kubectl get pod -n memstats-demo -w`

## Observe

1. Check reported memory — should be well above 1Mi:

   `kubectl top pod -n memstats-demo`

2. Confirm the value is realistic (>10Mi). Before the fix every container reported ~1Mi regardless of usage.

3. For deeper verification, find the kubelet stats endpoint on the node running the pod:

   `kubectl get pod -n memstats-demo -o wide`

   Then query the kubelet summary on that node — `workingSetBytes` should match the cgroup's `memory.current`.

## Teardown

`kubectl delete namespace memstats-demo`
