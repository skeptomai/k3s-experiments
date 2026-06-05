# Experiment 14: Horizontal Pod Autoscaler

## Status

**Blocked pending two Pelagos fixes:**

1. **CRI stats not implemented** ([#238](https://github.com/pelagos-containers/pelagos/issues/238), [#269](https://github.com/pelagos-containers/pelagos/issues/269)) — `kubectl top pod` returns no data for most pods; HPA's `FailedGetResourceMetric` condition fires continuously. Only pods with `hostPID: true` (e.g., SPIRE agents) report metrics via a different kernel path. Node-level metrics (`kubectl top nodes`) work fine.

2. **Mirror image naming regression in v0.65.25** ([#325](https://github.com/pelagos-containers/pelagos/issues/325)) — images pulled via a configured mirror are stored under the mirror's address, not the original registry reference, causing `pelagos run` to fail with "image not found locally." Workaround: `pelagos image tag <mirror-ref> <canonical-ref>` on each node after each pull.

The manifests are complete and correct. Once #238/#269 are resolved this experiment should work as written.

---

## What you'll observe

- A Deployment that starts at 1 replica and automatically scales to multiple replicas under CPU load
- The HPA control loop reading CPU metrics from metrics-server and calculating desired replica count
- Scale-up happening within ~60 seconds of load starting; scale-down after load stops (5-minute stabilization delay)
- How declaring CPU `requests` is what makes percentage-based autoscaling possible

## Concepts

### The HPA control loop

HPA is a Kubernetes controller that runs on a 15-second poll cycle. Each cycle it:

1. Reads current CPU utilization from metrics-server for all pods in the target Deployment
2. Computes `desiredReplicas = ceil(currentReplicas × (currentCPU / targetCPU))`
3. If desiredReplicas ≠ currentReplicas, patches the Deployment's `spec.replicas`

Example: 1 pod using 400m CPU, target is 50% of 200m request (= 100m):
```
desiredReplicas = ceil(1 × (400 / 100)) = ceil(4) = 4
```

### Why `requests` are required

HPA expresses the target as a percentage of the pod's CPU **request**, not its limit or the node's capacity. Without `requests` set, the denominator is undefined and HPA cannot function — it will emit a warning and refuse to scale.

This is also why the experiment from 06 (Resource Limits) is a prerequisite: once you understand requests vs limits, HPA's behavior follows naturally.

### Scale-up vs scale-down behavior

Scale-up is aggressive by default: HPA will scale up as soon as it observes utilization above the threshold for one polling cycle (~15s).

Scale-down is deliberately conservative: by default, HPA will not scale down until utilization has been below the threshold for **5 minutes** (the `scaleDown.stabilizationWindowSeconds` default). This prevents thrashing — a brief lull in traffic should not immediately drop replicas that will be needed again in seconds.

```
Scale up:   fast (1 poll cycle ≈ 15s to react)
Scale down: slow (5 min stabilization window by default)
```

### The workload image

The server uses `docker.io/library/python:3.12-alpine` running a Python HTTP server (mounted via ConfigMap) that computes `sum(sqrt(i) for i in range(50000))` on every GET request — deliberately CPU-hungry. The Python standard library `HTTPServer` processes one request at a time per thread; under concurrent load from the load generator, the single pod quickly saturates its CPU allocation.

The official Kubernetes HPA tutorial uses `registry.k8s.io/hpa-example` (a PHP/Apache image with a similar purpose), but that registry's images are stored under the mirror address in Pelagos's local store rather than under the original `registry.k8s.io` prefix, causing a lookup failure at container start time. Using `docker.io` images avoids this.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `hpa-demo` namespace |
| `configmap.yaml` | Python HTTP server script (CPU-burning per request) |
| `deployment.yaml` | python:3.12-alpine workload, 1 replica, 200m CPU request |
| `service.yaml` | ClusterIP on port 80 |
| `hpa.yaml` | HPA: min 1, max 6 replicas, target 50% CPU |
| `job-load.yaml` | Load generator: 600 concurrent wget requests to saturate CPU |

## Running it manually

```
kubectl apply -f experiments/14-hpa/
kubectl rollout status deployment/hpa-demo -n hpa-demo

# Watch the HPA in one terminal
kubectl get hpa hpa-demo -n hpa-demo --watch

# Apply load (separate terminal)
kubectl apply -f experiments/14-hpa/job-load.yaml

# After load finishes, watch scale-down (takes ~5 minutes)
kubectl get hpa hpa-demo -n hpa-demo --watch
```

## What the numbers mean

```
$ kubectl get hpa hpa-demo -n hpa-demo
NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
hpa-demo   Deployment/hpa-demo   <unknown>/50%   1         6         1          15s
hpa-demo   Deployment/hpa-demo   248%/50%        1         6         1          30s
hpa-demo   Deployment/hpa-demo   248%/50%        1         6         5          45s
hpa-demo   Deployment/hpa-demo   62%/50%         1         6         5          60s
```

- `<unknown>` — metrics-server hasn't scraped this pod yet (first ~15s)
- `248%/50%` — current 248%, target 50%; HPA will scale to ceil(1 × 248/50) = 5
- After scaling, 248% across 5 pods ≈ 49.6% average — just under target

## Relationship to other experiments

- **Experiment 06** (Resource Limits): `requests` must be set for HPA to work; this experiment proves why they matter beyond scheduling
- **Experiment 17** (Prometheus + Grafana): once you have the monitoring stack, you can observe HPA scaling events on a timeline dashboard rather than watching `kubectl get hpa --watch`
