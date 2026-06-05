# Experiment 15: StatefulSets

## What you'll observe

- Three pods named `web-0`, `web-1`, `web-2` — predictable names, not random suffixes
- Ordered startup: `web-0` must be Running and Ready before `web-1` starts, and so on
- Each pod gets its own PersistentVolumeClaim (`data-web-0`, `data-web-1`, `data-web-2`) that survives pod deletion and rescheduling
- Each pod is reachable by a stable DNS name (`web-0.web.stateful-demo.svc.cluster.local`) via the headless Service
- Each pod's storage holds its own identity — data written by `web-0` is never visible to `web-1` or `web-2`

## Concepts

### StatefulSet vs Deployment

A Deployment treats pods as interchangeable. If a pod is deleted, the replacement gets a new random name, a new IP, and (with a shared PVC) the same storage. This is fine for stateless workloads.

A StatefulSet makes three guarantees that Deployments don't:

| Property | Deployment | StatefulSet |
|----------|-----------|-------------|
| Pod names | `web-7d4b9c-xkz2p` (random) | `web-0`, `web-1`, `web-2` (stable) |
| Startup order | All at once | Sequential: 0 → 1 → 2 |
| Storage | Shared PVC or no PVC | Per-pod PVC, follows the pod |

### Stable pod identity

StatefulSet pods are named `<statefulset>-<ordinal>`. The ordinal is permanent — `web-0` is always `web-0`, even if the pod is deleted and rescheduled to a different node.

### Downward API for pod identity

Normally `hostname` inside a container returns the pod name (Kubernetes sets the UTS namespace hostname to `metadata.name`). Pelagos does not currently implement per-pod UTS namespaces, so `hostname` returns the container runtime's internal ID rather than the pod name.

The fix is the **Downward API** — Kubernetes's mechanism for injecting pod metadata into containers as environment variables or files:

```yaml
env:
  - name: POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
```

This injects `web-0` (or `web-1`, `web-2`) as `$POD_NAME` at runtime, without any application changes. The Downward API is the correct k8s-native way to give a container awareness of its own identity regardless of runtime UTS namespace behavior.

### Headless Service

The `clusterIP: None` Service does not get a virtual IP. Instead, DNS returns an A record directly for each pod:

```
web-0.web.stateful-demo.svc.cluster.local  → pod IP
web-1.web.stateful-demo.svc.cluster.local  → pod IP
web-2.web.stateful-demo.svc.cluster.local  → pod IP
```

This is how a database client can address `primary.db` and `replica-0.db` without a load balancer in the way.

### volumeClaimTemplates

Instead of mounting a single shared PVC, StatefulSets take a `volumeClaimTemplates` list. Kubernetes creates one PVC per pod:

```
data-web-0   (bound, used only by web-0)
data-web-1   (bound, used only by web-1)
data-web-2   (bound, used only by web-2)
```

If `web-1` is deleted, the `data-web-1` PVC is **not** deleted. When the pod is recreated (always as `web-1`), it rebinds to the same PVC and recovers its data. This is the property databases depend on.

### Ordered shutdown

Scale-down is the reverse: `web-2` is deleted first and must terminate before `web-1` is deleted. This allows a replica to drain or hand off leadership before going away.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `stateful-demo` namespace |
| `service.yaml` | Headless Service (`clusterIP: None`) for stable DNS |
| `statefulset.yaml` | 3-replica StatefulSet; initContainer writes pod name to NFS PVC; nginx serves it |
| `job-verify.yaml` | Verify job: GETs each pod by stable DNS name, checks it returns its own hostname |

## Running it manually

```
kubectl apply -f experiments/15-statefulsets/
kubectl rollout status statefulset/web -n stateful-demo --watch

# Watch ordered startup in real time
kubectl get pods -n stateful-demo --watch

# Check per-pod PVCs
kubectl get pvc -n stateful-demo

# Hit each pod by stable DNS (from within the cluster)
kubectl run -it --rm curl --image=docker.io/library/busybox:1.36 --restart=Never -- \
  sh -c 'for p in web-0 web-1 web-2; do echo "$p: $(wget -qO- http://$p.web.stateful-demo.svc.cluster.local)"; done'

# Prove data survives pod restart
kubectl delete pod web-1 -n stateful-demo
kubectl wait pod/web-1 -n stateful-demo --for=condition=ready --timeout=60s
kubectl run -it --rm curl --image=docker.io/library/busybox:1.36 --restart=Never -- \
  wget -qO- http://web-1.web.stateful-demo.svc.cluster.local
# Still returns "web-1" — same PVC reattached
```

## Relationship to other experiments

- **Experiment 04** (Persistent Volumes): StatefulSets use the same PV/PVC model, but automate per-pod provisioning via `volumeClaimTemplates`
- **Experiment 10** (NFS Storage): This experiment uses the `nfs` StorageClass for dynamic provisioning of per-pod volumes
- **Experiment 05** (RBAC): A real StatefulSet workload (e.g., etcd, Postgres) would add a ServiceAccount and Role to restrict what the pods can do via the API
