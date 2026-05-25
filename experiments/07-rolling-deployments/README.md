# Experiment 07: Rolling Deployments

## What you'll observe

- How `RollingUpdate` replaces pods incrementally without downtime
- What `maxSurge` and `maxUnavailable` control
- How to watch a rollout in real time with `kubectl rollout status`
- Rollout history and how Kubernetes tracks revisions
- What happens when you push a bad image — the rollout stalls rather than taking down the fleet
- How to recover with `kubectl rollout undo`

## Concepts

### RollingUpdate strategy

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
```

| Parameter | What it controls |
|-----------|-----------------|
| `maxSurge` | How many pods above the desired count can exist during the rollout. `1` means at most 4 pods running at once (3 desired + 1 new). |
| `maxUnavailable` | How many pods below the desired count are acceptable during the rollout. `0` means all 3 must be ready at all times — zero downtime. |

With `maxSurge: 1, maxUnavailable: 0`:
1. Kubernetes creates 1 new pod (now 4 total)
2. Waits for it to become Ready
3. Terminates 1 old pod (back to 3)
4. Repeat until all pods are on the new version

With `maxSurge: 0, maxUnavailable: 1` (the faster, lower-resource alternative):
1. Kubernetes terminates 1 old pod (now 2)
2. Creates 1 new pod (back to 3)
3. Repeat — but at the cost of briefly running below capacity

### Recreate strategy (not used here)

`type: Recreate` kills all pods first, then starts new ones. Causes downtime. Only
appropriate for workloads that cannot run two versions simultaneously.

---

## Apply

```
kubectl apply -f experiments/07-rolling-deployments/namespace.yaml && kubectl apply -f experiments/07-rolling-deployments/
```

Verify all 3 replicas are running:

```
kubectl get pods -n rolling-demo
```

Check the initial rollout is complete:

```
kubectl rollout status deployment/web -n rolling-demo
```

## Roll to a new version

Update the image to nginx:1.26:

```
kubectl set image deployment/web nginx=nginx:1.26 -n rolling-demo
```

Immediately watch the rollout:

```
kubectl rollout status deployment/web -n rolling-demo
```

You'll see output like:

```
Waiting for deployment "web" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 1 old replicas are pending termination...
deployment "web" successfully rolled out
```

While it's rolling you can also watch the pods directly:

```
kubectl get pods -n rolling-demo --watch
```

You'll see new pods (with new hash suffixes) come up as old ones terminate. At no
point does the count drop below 3 (because `maxUnavailable: 0`).

## Check rollout history

```
kubectl rollout history deployment/web -n rolling-demo
```

Shows the revision log:

```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

To see what image a specific revision used:

```
kubectl rollout history deployment/web -n rolling-demo --revision=1
```

## Trigger a bad rollout

Push an image tag that doesn't exist:

```
kubectl set image deployment/web nginx=nginx:this-tag-does-not-exist -n rolling-demo
```

Watch what happens:

```
kubectl get pods -n rolling-demo --watch
```

You'll see one new pod stuck in `ImagePullBackOff` or `ErrImagePull`. The rollout
stalls — Kubernetes won't proceed to replace more pods because the new version
isn't healthy. The other 3 pods on the previous good version keep running.

Confirm the stall:

```
kubectl rollout status deployment/web -n rolling-demo
```

It hangs, waiting for the new pod to become Ready.

This is the key safety property of a rolling deployment: **a bad update can only
damage one pod at a time, and it stops itself**. Your fleet stays up.

## Roll back

```
kubectl rollout undo deployment/web -n rolling-demo
```

This rolls back to the previous revision. Watch the bad pod disappear and the
deployment stabilise:

```
kubectl rollout status deployment/web -n rolling-demo
```

To roll back to a specific revision (not just the previous one):

```
kubectl rollout undo deployment/web -n rolling-demo --to-revision=1
```

Check history again — the rollback itself becomes a new revision:

```
kubectl rollout history deployment/web -n rolling-demo
```

## Teardown

```
kubectl delete namespace rolling-demo
```
