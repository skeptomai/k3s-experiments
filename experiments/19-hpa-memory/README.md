# Experiment 19: Memory-Based HPA

## What you'll observe

- An HPA that scales based on **memory usage** rather than CPU
- Scaling without a load generator — the pod already exceeds the target by holding ~30MB, so HPA scales up as soon as metrics are available
- The difference between CPU HPA (`averageUtilization` as % of request) and memory HPA (`averageValue` in absolute bytes)

## Concepts

### Why memory HPA uses AverageValue, not Utilization

CPU is compressible: a throttled container keeps running, just slower. Memory is not — a container that exceeds its limit gets OOMKilled. This distinction affects how HPA targets are expressed:

- **CPU** uses `averageUtilization` (% of request): "keep average CPU below 50% of what each pod requested"
- **Memory** typically uses `averageValue` (absolute bytes): "keep average memory below 20Mi per pod"

You *can* use `averageUtilization` for memory, but `averageValue` is more common because memory usage is easier to reason about in absolute terms, and because memory requests are often set conservatively.

### The HPA algorithm for AverageValue

```
desiredReplicas = ceil(currentReplicas × currentAverageValue / targetAverageValue)
```

This experiment: 1 pod using ~30Mi, target 20Mi per pod:
```
desiredReplicas = ceil(1 × 30Mi / 20Mi) = ceil(1.5) = 2
```

### No load generator needed

Unlike CPU HPA (exp 14), memory-based HPA doesn't need a separate load generator. The pods allocate their memory at startup and hold it. HPA observes that average memory exceeds the target and scales up immediately once metrics are available (~30s after pod start).

This also means scale-down doesn't happen automatically in this experiment — each new replica also holds 30Mi, and 30Mi > 20Mi, so HPA maintains the scaled-up replica count. To observe scale-down you would need to reduce the memory allocation or raise the target.

### Relationship to experiment 14 (CPU HPA) and experiment 17 (memory stats)

- **Exp 14**: CPU-based HPA — `averageUtilization`, load generator required, scales up then down
- **Exp 17**: verifies the Pelagos memory stats fix that makes this experiment possible (Pelagos #328)
- **Exp 19**: memory-based HPA — `averageValue`, no load generator, demonstrates the absolute-bytes targeting model

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `hpa-mem-demo` namespace |
| `deployment.yaml` | busybox pod holding ~30MB; requests 16Mi so HPA can compute utilization |
| `hpa.yaml` | HPA: min 1, max 4, target averageValue 20Mi memory |

## Running manually

```
kubectl apply -f experiments/19-hpa-memory/
kubectl rollout status deployment/hpa-mem-demo -n hpa-mem-demo

# Watch HPA — should scale to 2 replicas within ~60s
kubectl get hpa hpa-mem-demo -n hpa-mem-demo --watch
```
