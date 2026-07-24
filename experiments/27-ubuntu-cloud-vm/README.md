# Experiment 27 — Ubuntu cloud VM with virtctl SSH jump

Demonstrates a full-stack KubeVirt SSH workflow using a real Ubuntu 24.04 cloud image
where cloud-init correctly handles `ssh_authorized_keys` — no manual key injection
needed. Reuses the RBAC and virtctl jump container from experiment 26.

## How it works

- Ubuntu 24.04 minimal cloud image packed as a KubeVirt `containerDisk`
- `cloudInitNoCloud` userData passes the RSA public key via `ssh_authorized_keys`
- cloud-init runs on first boot, installs the key into `/home/ubuntu/.ssh/authorized_keys`
- A jump pod (same ServiceAccount + image from exp 26) SSHes in via `virtctl ssh`,
  which tunnels through the Kubernetes API portforward subresource

No direct network path from omen to the VM is needed — the SSH connection travels:
`jump pod → kubelet API → virt-handler → virtqemud → QEMU serial/virtio → sshd`

## Files

| File | Purpose |
|------|---------|
| `vmi-ubuntu.yaml` | Ubuntu 24.04 VMI (2 cores, 1Gi RAM) with cloud-init SSH key injection |
| `jump-job.yaml` | Job that SSHes into the VM and runs a command |

## Prerequisites

This experiment reuses resources from experiment 26:

- `vm-jump` ServiceAccount + RBAC (`experiments/26-virtctl-ssh-jump/rbac.yaml`)
- `vm-ssh-key` Secret (RSA 2048 private key)
- `192.168.89.2:5004/kubevirt/virtctl-jump:v1.8.4-ssh` container image

Apply exp 26 RBAC if not already present:
```bash
kubectl apply -f experiments/26-virtctl-ssh-jump/rbac.yaml
```

## Container disk image

The Ubuntu disk image is packed as a KubeVirt `containerDisk` — a container with the
disk image at `/disk/disk.img`. Build and push it once:

```bash
wget https://cloud-images.ubuntu.com/minimal/releases/24.04/release/ubuntu-24.04-minimal-cloudimg-amd64.img
```

Create `ubuntu-disk.dockerfile`:
```dockerfile
FROM scratch
ADD ubuntu-24.04-minimal-cloudimg-amd64.img /disk/disk.img
```

```bash
sudo pelagos build -f ubuntu-disk.dockerfile -t 192.168.89.2:5004/ubuntu/ubuntu-cloud-disk:24.04 .
sudo pelagos image push --insecure 192.168.89.2:5004/ubuntu/ubuntu-cloud-disk:24.04
```

The image is already in the local registry — rebuild only if the base image changes.

## Running

### 1. Start the VM

```bash
kubectl create -f experiments/27-ubuntu-cloud-vm/vmi-ubuntu.yaml
kubectl get vmi ubuntu-cloud -w
```

Wait for `Running`. The VM takes ~30–60 seconds for cloud-init to complete after entering
Running state.

### 2. Run the jump job

```bash
kubectl create -f experiments/27-ubuntu-cloud-vm/jump-job.yaml
kubectl logs -l job-name=ubuntu-ssh-jump --follow
```

Expected output:
```
Linux ubuntu-cloud 6.8.0-134-generic #134-Ubuntu SMP PREEMPT_DYNAMIC Fri Jun 26 18:43:11 UTC 2026 x86_64
status: done
SSH-jump-success
```

`cloud-init status: done` confirms key injection completed before the SSH landed.

### 3. Cleanup

```bash
kubectl delete job ubuntu-ssh-jump
kubectl delete vmi ubuntu-cloud
```

## Why Ubuntu instead of CirrOS

CirrOS (experiment 25/26) uses a stripped-down cloud-init reimplementation that silently
ignores `ssh_authorized_keys`. It also ships Dropbear v2018.76, which only speaks legacy
`ssh-rsa` (SHA1) — requiring explicit `PubkeyAcceptedAlgorithms=+ssh-rsa` on the
client.

Ubuntu cloud images include:
- Full cloud-init: `ssh_authorized_keys` works out of the box
- Current OpenSSH server: ed25519 and `rsa-sha2-256` work; no legacy flags needed
- `ubuntu` user pre-created by cloud-init with `sudo` access

The jump job connects as `ubuntu` with no password, no manual setup.
