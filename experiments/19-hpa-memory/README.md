# Experiment 19 — Memory-Based HPA

Kubernetes HPA supports memory as a scaling metric, but memory behaves differently from CPU: it is non-compressible, so exceeding a limit causes an OOMKill rather than throttling. This experiment demonstrates how to express memory targets using `averageValue` (absolute bytes) rather than `averageUtilization`, and shows that memory-based HPA requires no separate load generator — the pod allocates ~30Mi at startup, immediately exceeding the 20Mi target, so HPA scales up as soon as metrics are available.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `hpa-mem-demo` namespace |
| `deployment.yaml` | busybox pod that allocates and holds ~30MB; requests 16Mi so HPA can compute a ratio |
| `hpa.yaml` | HPA targeting memory `averageValue: 20Mi`, min 1 / max 4 replicas |

## Apply

```
kubectl apply -f experiments/19-hpa-memory/
```

## Observe

1. Wait for the pod to be running and metrics to populate (~30s):

   `kubectl rollout status deployment/hpa-mem-demo -n hpa-mem-demo`

2. Watch HPA scale from 1 to 2 replicas. With 1 pod at ~30Mi and a target of 20Mi, the algorithm gives `ceil(1 × 30Mi / 20Mi) = 2`:

   `kubectl get hpa hpa-mem-demo -n hpa-mem-demo --watch`

3. Note that scale-down does not occur — each new replica also holds ~30Mi, keeping average memory above the 20Mi target. To observe scale-down, raise `averageValue` or reduce the allocation in the deployment.

4. Compare with experiment 14 (CPU HPA), which uses `averageUtilization` and requires a load generator to drive CPU up then lets it fall for scale-down.

## Teardown

`kubectl delete namespace hpa-mem-demo`
