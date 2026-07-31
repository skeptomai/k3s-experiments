# Experiment 25 — KubeVirt VMs (and the Two-Pod Race Bug)

KubeVirt runs virtual machines as Kubernetes pods, letting you schedule VMs alongside
containers on the same cluster nodes. This experiment launches a CirrOS VM as a
VirtualMachineInstance (VMI) using a container disk — an OCI image that carries the
VM disk image. It also documents a critical race condition discovered during bringup:
on HA clusters with multiple API servers, virt-controller creates two virt-launcher
pods per VMI, which blocks the VMI from ever starting.

## Files

| File | Purpose |
|------|---------|
| `vmi-cirros.yaml` | VMI using a container disk (quay.io/kubevirt/cirros-container-disk-demo), pinned to ipc8 |
| `vmi-cirros-hostdisk.yaml` | Alternate VMI using a hostDisk volume at `/tmp/cirros.img` on ipc8 |
| `virt-controller-build-job.yaml` | Build job that compiles the patched virt-controller from skeptomai/kubevirt and pushes to the local registry |
| `virt-controller-two-pod-race-bug.md` | Root-cause analysis of the two-pod race bug (HTTP 409 + podExpectations bypass on HA API servers) |
| `DEBUG.md` | Forensic debug log: bpftrace captures, libvirt hook analysis, and proof that QEMU never exec'd |

## Apply

Apply the VMI:

```
kubectl apply -f experiments/25-kubevirt-vm/vmi-cirros.yaml
```

If the two-pod race bug is present (stock KubeVirt v1.8.4 on an HA cluster), build and
deploy the patched virt-controller first:

```
kubectl apply -f experiments/25-kubevirt-vm/virt-controller-build-job.yaml
```

Wait for the build job to complete, then update the KubeVirt CR to use the patched image
from `192.168.89.2:5004/kubevirt/virt-controller:skeptomai-v1.8.4`.

## Observe

Watch the VMI come up:

```
kubectl get vmi cirros-test -w
```

Expected progression: `Scheduling → Scheduled → Running`. If two virt-launcher pods
appear simultaneously the race bug is present — see `virt-controller-two-pod-race-bug.md`.

Check which node the VM landed on and that only one launcher pod exists:

```
kubectl get pods -l kubevirt.io=virt-launcher -o wide
```

Once `Running`, access the VM console:

```
kubectl virt console cirros-test
```

Log in as `cirros` / `gocubsgo`. Verify network by pinging the pod gateway:

```
ip route; ping -c3 10.0.2.2
```

Check live-migrability (KubeVirt marks VMIs with the `LiveMigratable` condition):

```
kubectl get vmi cirros-test -o jsonpath='{.status.conditions}' | jq .
```

## Teardown

```
kubectl delete vmi cirros-test
```

For the hostDisk variant: `kubectl delete vmi cirros-hostdisk`. The build job (if applied)
can be removed with `kubectl delete -f experiments/25-kubevirt-vm/virt-controller-build-job.yaml`.
