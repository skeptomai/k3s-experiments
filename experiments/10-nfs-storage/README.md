# Experiment 10 — NFS Persistent Storage

NFS-backed dynamic provisioning lets pods claim durable storage without knowing anything
about the underlying NFS server. This experiment uses `nfs-subdir-external-provisioner`
to create a `nfs` StorageClass backed by TrueNAS on nazgul — pods request a PVC and the
provisioner fulfills it by carving out a subdirectory automatically. The key payoff is
`ReadWriteMany`: multiple pods on different nodes can mount the same volume simultaneously,
which StatefulSets and other distributed workloads require.

## Files

| File | Purpose |
|------|---------|
| `helm-values.yaml` | Helm values for the NFS provisioner — points at nazgul, sets `nfs` as the default StorageClass with `Retain` reclaim policy |
| `test-pvc.yaml` | PVC + Pod that verifies end-to-end: claims 1Gi via the `nfs` StorageClass and writes a file to it |

## Apply

Install the provisioner via Helm (one-time setup):

```
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner && helm repo update
helm install nfs-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner --namespace kube-system -f experiments/10-nfs-storage/helm-values.yaml
```

Then run the test workload:

```
kubectl apply -f experiments/10-nfs-storage/test-pvc.yaml
```

## Observe

Watch the PVC bind — it should go `Pending → Bound` within a few seconds:

```
kubectl get pvc nfs-test -w
```

Check the pod completed successfully:

```
kubectl logs nfs-test
```

On nazgul, a new subdirectory appears under `/mnt/primary_storage/k8s-nfs` named
`default-nfs-test-<pvname>`. That directory persists independently of the pod.

Verify the StorageClass was installed as default:

```
kubectl get storageclass
```

## Teardown

```
kubectl delete -f experiments/10-nfs-storage/test-pvc.yaml
```

The subdirectory on nazgul is **not** deleted automatically — the `Retain` reclaim policy
renames it with an `archived-` prefix. Remove it manually on nazgul when no longer needed.
