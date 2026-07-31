# Experiment 15 — StatefulSets

StatefulSets solve the problem of state-bearing workloads where each replica must maintain a stable identity across restarts and rescheduling. Unlike a Deployment, which treats pods as interchangeable, a StatefulSet gives each pod a permanent ordinal name, a dedicated PersistentVolumeClaim that survives pod deletion, and a stable DNS entry via a headless Service — the combination that makes databases, queues, and other clustered stateful applications possible on Kubernetes.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `stateful-demo` namespace |
| `service.yaml` | Headless Service (`clusterIP: None`) that gives each pod a stable DNS name |
| `statefulset.yaml` | Three-replica nginx StatefulSet with per-pod PVCs and Downward API identity injection |
| `job-verify.yaml` | Verification Job that curls each pod by stable DNS name and checks it serves its own identity |

## Apply

Apply in order — the namespace must exist before the other resources:

```
kubectl apply -f experiments/15-statefulsets/namespace.yaml
kubectl apply -f experiments/15-statefulsets/service.yaml
kubectl apply -f experiments/15-statefulsets/statefulset.yaml
```

Wait for all three pods to be Running and Ready:

```
kubectl get pods -n stateful-demo -w
```

Pods start sequentially: `web-0` must be Ready before `web-1` starts, and `web-1` before `web-2`.

## Observe

**1. Stable pod names and ordered startup**

```
kubectl get pods -n stateful-demo
```

Pods are named `web-0`, `web-1`, `web-2` — no random suffix. Check `kubectl describe statefulset web -n stateful-demo` to see the ordered rollout recorded in events.

**2. Per-pod PersistentVolumeClaims**

```
kubectl get pvc -n stateful-demo
```

Three PVCs are created: `data-web-0`, `data-web-1`, `data-web-2`. Delete a pod and watch it recreate and rebind to the same PVC:

```
kubectl delete pod web-1 -n stateful-demo
kubectl get pvc -n stateful-demo
```

The `data-web-1` PVC is not deleted and the replacement `web-1` picks it up.

**3. Stable DNS and per-pod identity**

Run the verify Job to confirm each pod is reachable by its stable DNS name and serves its own identity (the init container wrote `$POD_NAME` to `/data/index.html` via the Downward API):

```
kubectl apply -f experiments/15-statefulsets/job-verify.yaml
kubectl logs -n stateful-demo job/verify
```

Expected output: each pod responds with its own name (`web-0`, `web-1`, `web-2`), proving storage and DNS identity are per-pod and isolated.

**4. Downward API identity**

The init container uses `fieldRef: metadata.name` to inject the pod name as `$POD_NAME`. This is the correct Kubernetes-native approach when the container runtime does not implement per-pod UTS namespaces — no application change required.

## Teardown

```
kubectl delete namespace stateful-demo
```

Note: deleting the namespace deletes the pods and PVCs. The PVCs are intentionally not deleted on pod deletion alone — that is the StatefulSet guarantee.
