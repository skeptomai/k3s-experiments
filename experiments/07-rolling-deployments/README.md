# Experiment 07 — Rolling Deployments

Rolling updates let Kubernetes swap pods from an old version to a new one incrementally,
without taking the service offline. The `RollingUpdate` strategy — controlled by
`maxSurge` and `maxUnavailable` — determines how many pods can be in-flight at once,
letting you trade speed against capacity headroom. This experiment makes those knobs
tangible: a slow, zero-downtime rollout, a bad-image stall, and a recovery via `kubectl
rollout undo`.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `rolling-demo` namespace |
| `deployment.yaml` | 3-replica nginx Deployment with `maxSurge: 1, maxUnavailable: 0` — zero-downtime rollout |

## Apply

```
kubectl apply -f experiments/07-rolling-deployments/namespace.yaml && kubectl apply -f experiments/07-rolling-deployments/
```

Confirm all 3 replicas are Running and the initial rollout is complete:

```
kubectl rollout status deployment/web -n rolling-demo
```

## Observe

### Rolling to a new version

Trigger a rollout by updating the image:

```
kubectl set image deployment/web nginx=nginx:1.26 -n rolling-demo
```

Watch it progress:

```
kubectl rollout status deployment/web -n rolling-demo
```

You'll see each pod replaced one at a time. Because `maxUnavailable: 0`, the ready count
never drops below 3 — a fourth pod (the surge) comes up and is verified Ready before an
old pod is terminated.

Watch pods directly to see the new ReplicaSet hash appear alongside the old one:

```
kubectl get pods -n rolling-demo -w
```

### Rollout history

```
kubectl rollout history deployment/web -n rolling-demo
```

Each `kubectl set image` (or any spec change) creates a new revision. To inspect what
image a specific revision used:

```
kubectl rollout history deployment/web -n rolling-demo --revision=1
```

### Simulating a bad rollout

Push a nonexistent image:

```
kubectl set image deployment/web nginx=nginx:does-not-exist -n rolling-demo
```

The new pod enters `ImagePullBackOff`. With `maxUnavailable: 0`, the old pods are never
terminated — the fleet stays up at full capacity while the bad rollout stalls.

```
kubectl get pods -n rolling-demo
```

Recover by rolling back to the last good revision:

```
kubectl rollout undo deployment/web -n rolling-demo
```

## Teardown

```
kubectl delete namespace rolling-demo
```
