# Experiment 14 — Horizontal Pod Autoscaler

Horizontal Pod Autoscaler (HPA) closes the loop between observed load and declared
replica count — freeing you from manually scaling Deployments up and down. This
experiment shows HPA reading CPU metrics from metrics-server, computing desired replicas
using the utilization formula, and driving a Deployment from 1 replica up to 6 under
synthetic CPU load. Understanding why `resources.requests` is required (it is the
denominator in the utilization calculation) is the key insight here.

> **Status: blocked pending Pelagos CRI stats fix** — HPA's `FailedGetResourceMetric`
> condition fires continuously because pod-level CPU stats are not yet reported by the
> Pelagos CRI ([#238](https://github.com/pelagos-containers/pelagos/issues/238),
> [#269](https://github.com/pelagos-containers/pelagos/issues/269)). The manifests are
> complete and correct; this experiment will work as written once those issues are resolved.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `hpa-demo` namespace |
| `configmap.yaml` | Python HTTP server script that does deliberate CPU work per request |
| `deployment.yaml` | 1-replica Deployment running the compute server; CPU request=200m, limit=500m |
| `service.yaml` | ClusterIP Service exposing the compute server pods on port 80 |
| `hpa.yaml` | HPA targeting 50% average CPU utilization, scaling between 1 and 6 replicas |
| `job-load.yaml` | Load generator Job that fires 3000 concurrent wget requests at the service |

## Apply

Apply the namespace first, then the rest in any order:

```
kubectl apply -f experiments/14-hpa/namespace.yaml
kubectl apply -f experiments/14-hpa/
```

## Observe

Watch HPA status — this is the main event:

```
kubectl get hpa -n hpa-demo -w
```

You'll see `TARGETS` show current vs target utilization and `REPLICAS` climb as load arrives. Once the load Job finishes, replicas stay elevated for the 5-minute scale-down stabilization window before dropping back to 1.

Start the load generator:

```
kubectl apply -f experiments/14-hpa/job-load.yaml
```

Watch pods scale up in real time:

```
kubectl get pods -n hpa-demo -w
```

Describe the HPA to see the control loop's decisions and any conditions:

```
kubectl describe hpa hpa-demo -n hpa-demo
```

The `Events` section will show each scaling decision with the utilization ratio that triggered it.

## How the math works

HPA polls metrics-server every 15 seconds and computes:

```
desiredReplicas = ceil(currentReplicas × (currentCPU / targetCPU))
```

With `averageUtilization: 50` and a CPU request of `200m`, the target per pod is 100m.
If 1 pod is using 400m: `ceil(1 × (400 / 100)) = 4 replicas`.

Without `resources.requests` set, the denominator is undefined and HPA refuses to scale.
Scale-up reacts within one poll cycle (~15s); scale-down waits the full 5-minute
stabilization window to avoid thrashing.

## Teardown

```
kubectl delete namespace hpa-demo
```
