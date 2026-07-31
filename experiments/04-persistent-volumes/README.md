# Experiment 04 — Persistent Volumes

Kubernetes pods are ephemeral — when one dies, its filesystem goes with it. PersistentVolumes (PVs) decouple storage from pod lifecycle. This experiment demonstrates how a PersistentVolumeClaim (PVC) requests storage, how the NFS provisioner fulfills it automatically, and the critical lesson that data survives pod deletion and recreation because it lives on the volume, not in the container.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `pv-demo` namespace |
| `pvc.yaml` | PVC requesting 100Mi from the `nfs` StorageClass (ReadWriteOnce) |
| `deployment.yaml` | Single-replica busybox Deployment that writes a timestamped line to `/data/log.txt` on startup |

## Prerequisites

The `nfs` StorageClass must be installed (see experiment 10). It is backed by the NFS server on nazgul (`192.168.89.2:/mnt/primary_storage/k8s-nfs`) and has reclaim policy `Retain`.

## Apply

```
kubectl apply -f experiments/04-persistent-volumes/namespace.yaml && kubectl apply -f experiments/04-persistent-volumes/
```

## Observe

Check PVC binding — the NFS provisioner binds immediately on PVC creation (unlike `local-path` which defers until a pod is scheduled):

```
kubectl get pvc -n pv-demo
```

Once `Bound`, a PV was auto-created:

```
kubectl get pv
```

Note `RECLAIM POLICY: Retain` — the PV and its data survive PVC deletion.

Read the log the pod wrote at startup:

```
kubectl exec -n pv-demo $(kubectl get pod -n pv-demo -o name | head -1) -- cat /data/log.txt
```

Write additional data manually:

```
kubectl exec -n pv-demo $(kubectl get pod -n pv-demo -o name | head -1) -- sh -c 'echo "manual entry at $(date)" >> /data/log.txt'
```

## The key test: data survives pod deletion

Delete the pod (the Deployment recreates it immediately):

```
kubectl delete pod -n pv-demo $(kubectl get pod -n pv-demo -o name | head -1 | sed 's|pod/||')
```

Once the replacement is running, read the log:

```
kubectl exec -n pv-demo $(kubectl get pod -n pv-demo -o name | head -1) -- cat /data/log.txt
```

Both the original and manual entries are still there, and the new pod appended its own start line. The data lived on the NFS volume, not in the container.

## Teardown

Deleting the namespace removes the PVC, but because the reclaim policy is `Retain`, the PV remains. Clean up both:

```
kubectl delete namespace pv-demo && kubectl delete pv $(kubectl get pv -o json | python3 -c "import sys,json; [print(p['metadata']['name']) for p in json.load(sys.stdin)['items'] if p.get('spec',{}).get('claimRef',{}).get('namespace')=='pv-demo']")
```
