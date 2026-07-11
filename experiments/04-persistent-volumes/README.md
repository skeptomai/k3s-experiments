# Experiment 04: Persistent Volumes

## What you'll observe

- How a PersistentVolumeClaim (PVC) requests storage from the cluster
- How k3s auto-provisions a PersistentVolume (PV) via the built-in `local-path` StorageClass
- That PVC status starts as `Pending` and only binds when a pod actually claims it
- That data written to a mounted volume survives pod deletion and recreation
- What happens to the PV when you delete the PVC (spoiler: data is gone)

## Concepts

| Term | What it is |
|------|------------|
| PersistentVolume (PV) | The actual storage resource — a directory on a node's disk |
| PersistentVolumeClaim (PVC) | Your request for storage; Kubernetes binds it to a PV |
| StorageClass | Tells k3s *how* to provision the PV. k3s ships with `local-path` which provisions a directory on whichever node runs the pod |
| AccessMode `ReadWriteOnce` | The volume can be mounted read-write by one node at a time |

## Apply

```
kubectl apply -f experiments/04-persistent-volumes/namespace.yaml && kubectl apply -f experiments/04-persistent-volumes/
```

## Observe PVC binding

Right after apply, check the PVC:

```
kubectl get pvc -n pv-demo
```

You'll see `STATUS: Pending`. The `local-path` provisioner uses **WaitForFirstConsumer** — it doesn't create the PV until a pod actually needs it. Once the pod is scheduled:

```
kubectl get pvc -n pv-demo
```

Now it shows `Bound`. A PV was auto-created:

```
kubectl get pv
```

Note the `RECLAIM POLICY: Delete` — this is important for teardown.

## Verify the pod wrote to the volume

Get the pod name:

```
kubectl get pods -n pv-demo
```

Read the log file on the volume:

```
kubectl exec -n pv-demo <pod-name> -- cat /data/log.txt
```

You'll see a timestamped line written when the pod started.

## Write more data manually

```
kubectl exec -n pv-demo <pod-name> -- sh -c 'echo "manual entry at $(date)" >> /data/log.txt'
```

Read it back:

```
kubectl exec -n pv-demo <pod-name> -- cat /data/log.txt
```

## The key test: delete the pod and prove data persists

Delete the pod (the Deployment will recreate it immediately):

```
kubectl delete pod -n pv-demo <pod-name>
```

Watch the new pod come up:

```
kubectl get pods -n pv-demo
```

Exec into the new pod and read the log:

```
kubectl exec -n pv-demo <new-pod-name> -- cat /data/log.txt
```

You'll see both the original entry and the manual entry. The new pod also appended its own start line. The data lived on the volume, not in the container — so it survived the pod being destroyed.

## Where is the data actually stored?

The `local-path` provisioner creates a directory on the node that scheduled the pod. You can see which node:

```
kubectl get pod -n pv-demo <pod-name> -o wide
```

On that node (e.g., ipc7), the data lives under `/var/lib/rancher/k3s/storage/`.

## Teardown and reclaim policy

Delete the namespace (which deletes the PVC):

```
kubectl delete namespace pv-demo
```

Now check the PV:

```
kubectl get pv
```

Because the reclaim policy is `Delete`, the PV and its data are automatically deleted when the PVC is removed. If the policy were `Retain`, the PV would stay and need manual cleanup — useful when you need to recover data before decommissioning.
