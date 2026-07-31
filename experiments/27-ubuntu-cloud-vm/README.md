# Experiment 27 — Ubuntu cloud VM with virtctl SSH jump

This experiment demonstrates KubeVirt's cloud-init integration using a real Ubuntu 24.04 cloud image, where `ssh_authorized_keys` in the userData payload causes cloud-init to install the public key before sshd accepts connections. It extends experiment 26's virtctl jump pattern to a production-grade OS, showing that the same RBAC and jump container work unchanged — only the guest image and cloud-init config differ.

## Files

| File | Purpose |
|------|---------|
| `vmi-ubuntu.yaml` | Ubuntu 24.04 VMI (2 cores, 1Gi RAM) with cloudInitNoCloud SSH key injection |
| `jump-job.yaml` | Job that SSHes into the VM via virtctl and runs a command to verify cloud-init completed |

## Prerequisites

This experiment reuses resources from experiment 26. Apply the RBAC and create the SSH key secret if not already present:

```
kubectl apply -f experiments/26-virtctl-ssh-jump/rbac.yaml
```

The `vm-ssh-key` Secret and `192.168.89.2:5004/kubevirt/virtctl-jump:v1.8.4-ssh` image must also exist from experiment 26.

## Container disk

The Ubuntu disk image is packaged as a KubeVirt `containerDisk` and pushed to the local registry. Build and push it once (skip if already present):

```
wget https://cloud-images.ubuntu.com/minimal/releases/24.04/release/ubuntu-24.04-minimal-cloudimg-amd64.img && printf 'FROM scratch\nADD ubuntu-24.04-minimal-cloudimg-amd64.img /disk/disk.img\n' > ubuntu-disk.dockerfile && sudo pelagos build -f ubuntu-disk.dockerfile -t 192.168.89.2:5004/ubuntu/ubuntu-cloud-disk:24.04 . && sudo pelagos image push --insecure 192.168.89.2:5004/ubuntu/ubuntu-cloud-disk:24.04
```

## Apply

Start the VM:

```
kubectl apply -f experiments/27-ubuntu-cloud-vm/vmi-ubuntu.yaml
```

Wait for it to reach Running state:

```
kubectl get vmi ubuntu-cloud -w
```

Then run the SSH jump job:

```
kubectl apply -f experiments/27-ubuntu-cloud-vm/jump-job.yaml
```

## Observe

1. Watch the VMI reach Running — cloud-init runs inside the guest during first boot, which takes 30–60 seconds after the VMI is Running.

2. Tail the jump job logs:

   ```
   kubectl logs -l job-name=ubuntu-ssh-jump --follow
   ```

   Expected output:
   ```
   Linux ubuntu-cloud 6.8.0-134-generic ...
   status: done
   SSH-jump-success
   ```

   `cloud-init status: done` confirms key injection completed before the SSH session landed. The virtctl tunnel path is: jump pod → kubelet portforward → virt-handler → virtqemud → QEMU → sshd. No direct network path from the jump pod to the VM is required.

## Teardown

```
kubectl delete -f experiments/27-ubuntu-cloud-vm/jump-job.yaml -f experiments/27-ubuntu-cloud-vm/vmi-ubuntu.yaml
```
