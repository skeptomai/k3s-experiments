# Experiment 10: NFS Persistent Storage

## What you'll observe

- PersistentVolumeClaims are fulfilled automatically by the NFS provisioner
- Each PVC gets its own subdirectory on the NFS server under `/mnt/primary_storage/k8s-nfs`
- Storage survives pod restarts and rescheduling across nodes
- `ReadWriteMany` access mode allows multiple pods on different nodes to share a volume simultaneously

## Infrastructure

NFS server: `nazgul.home.skeptomai.com` (192.168.89.2), TrueNAS SCALE  
Export: `/mnt/primary_storage/k8s-nfs`  
StorageClass: `nfs` (default)

## Setup

### Install the NFS provisioner via Helm

```
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner
helm repo update
helm install nfs-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner --namespace kube-system -f helm-values.yaml
```

### Verify

```
sudo kubectl get storageclass
sudo kubectl get pods -n kube-system | grep nfs
```

### Run the test

```
sudo kubectl apply -f test-pvc.yaml
sudo kubectl get pvc nfs-test
sudo kubectl logs nfs-test
```

The PVC should bind within a few seconds. On nazgul you'll see a new subdirectory
appear under `/mnt/primary_storage/k8s-nfs`.

### Clean up

```
sudo kubectl delete -f test-pvc.yaml
sudo kubectl delete pvc nfs-test
```

## Concepts

`nfs-subdir-external-provisioner` is a dynamic provisioner — it watches for PVC
creation events and fulfills them by creating a subdirectory on the NFS server. The
subdirectory is named `${namespace}-${pvcname}-${pvname}` for easy identification.

`reclaimPolicy: Retain` means that when a PVC is deleted, the underlying directory
on the NFS server is kept (renamed with an `archived-` prefix). This prevents
accidental data loss. Delete the directories on nazgul manually when you're sure
you no longer need the data.
