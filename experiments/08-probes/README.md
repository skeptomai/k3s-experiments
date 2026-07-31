# Experiment 08 — Liveness and Readiness Probes

Kubernetes probes let the control plane distinguish between a container that is alive
and one that is ready to serve traffic — two different things with different consequences
when they fail. This experiment makes both behaviors tangible: a liveness probe failure
triggers a container restart (the RESTARTS counter climbs), while a readiness probe
failure removes the pod from Service endpoints without killing it. Understanding this
distinction is essential for writing production workloads that degrade gracefully instead
of dropping traffic or looping in crash restarts.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `probes-demo` namespace |
| `deployment-liveness.yaml` | Busybox pod that deletes `/tmp/healthy` after 30s, triggering exec liveness probe failures and restarts |
| `deployment-readiness-ok.yaml` | Nginx pod with a readiness probe on `/` — succeeds, pod receives traffic |
| `deployment-readiness-fail.yaml` | Nginx pod with a readiness probe on `/healthz` — 404, pod is excluded from endpoints |
| `service.yaml` | Service selecting both readiness pods; only the passing one appears in endpoints |

## Apply

```
kubectl apply -f experiments/08-probes/namespace.yaml && kubectl apply -f experiments/08-probes/
```

## Observe

### Liveness: container killed and restarted

Watch the liveness-demo pod cycle through restarts:

```
kubectl get pods -n probes-demo -w
```

The busybox container creates `/tmp/healthy` on start, sleeps 30 seconds, then deletes
it. The liveness probe runs `cat /tmp/healthy` every 5 seconds with a failure threshold
of 3 — so about 15 seconds after the file disappears, the container is killed and
restarted. The RESTARTS counter increments roughly every 45 seconds.

Describe the pod to see the probe failure events:

```
kubectl describe pod -n probes-demo -l app=liveness-demo
```

The Events section will show `Liveness probe failed` followed by `Container busybox failed liveness probe, will be restarted`.

### Readiness: pod alive but cut from traffic

```
kubectl get pods -n probes-demo -l app=readiness-demo
```

You'll see one pod `1/1 Ready` (probing `/`, which nginx serves) and one `0/1 Ready`
(probing `/healthz`, which returns 404). Both are Running — neither is restarted.

Check the Service endpoints to confirm only the healthy pod receives traffic:

```
kubectl get endpoints -n probes-demo readiness-demo
```

Only the IP of the `readiness-ok` pod appears in the endpoint list.

## Teardown

```
kubectl delete namespace probes-demo
```
