# Experiment 26 — virtctl SSH jump from a container

Demonstrates SSHing into a KubeVirt VM from a pod running inside the same cluster,
using `virtctl ssh` tunneled through the Kubernetes API — no direct network path to
the VM required.

## How it works

`virtctl ssh` proxies the SSH connection through the Kubernetes API server via the
`subresources.kubevirt.io/virtualmachineinstances/portforward` subresource — the same
mechanism as `kubectl port-forward`. The jump pod holds the private key as a Secret
and uses the in-cluster service account token for API authentication. No kubeconfig
file is needed; Kubernetes injects the API server address and token into every pod
automatically.

## Files

| File | Purpose |
|------|---------|
| `vmi-cirros-ssh.yaml` | CirrOS VMI with a cloud-init `#cloud-config` stub (see gotcha below) |
| `rbac.yaml` | ServiceAccount `vm-jump`, Role, and RoleBinding |
| `ssh-keypair-secret.yaml` | Documents how to create the `vm-ssh-key` Secret (key not embedded) |
| `jump-job.yaml` | Job that SSHes into the VMI and runs a command |

## Setup

### 1. Generate an RSA keypair

```bash
ssh-keygen -t rsa -b 2048 -f /tmp/vm-ssh-rsa -N "" -C "vm-jump-experiment"
```

RSA is required — see the Dropbear gotcha below.

### 2. Create the Secret

```bash
kubectl create secret generic vm-ssh-key --from-file=id_rsa=/tmp/vm-ssh-rsa
```

### 3. Apply RBAC and start the VMI

```bash
kubectl apply -f rbac.yaml -f vmi-cirros-ssh.yaml
```

Wait for the VMI to reach `Running`:
```bash
kubectl get vmi cirros-ssh -w
```

### 4. Inject the SSH public key into the VM (manual step — see gotcha below)

```bash
VM_IP=$(kubectl get vmi cirros-ssh -o jsonpath='{.status.interfaces[0].ipAddress}')
PUBKEY=$(cat /tmp/vm-ssh-rsa.pub)
sshpass -p gocubsgo ssh -o StrictHostKeyChecking=no cirros@$VM_IP \
  "mkdir -p ~/.ssh && echo \"$PUBKEY\" >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
```

Default CirrOS credentials: `cirros` / `gocubsgo`.

### 5. Run the jump job

```bash
kubectl apply -f jump-job.yaml
kubectl logs -l job-name=vm-ssh-jump
```

Expected output:
```
Linux cirros-ssh 5.3.0-26-generic ...
 HH:MM:SS up X min, ...
SSH-jump-success
```

## Container image

The jump container uses a custom image built from Alpine + the `virtctl` binary +
`openssh-client`, pushed to the local registry:

```
192.168.89.2:5004/kubevirt/virtctl-jump:v1.8.4-ssh
```

To rebuild:
```bash
curl -sL https://github.com/kubevirt/kubevirt/releases/download/v1.8.4/virtctl-v1.8.4-linux-amd64 -o /tmp/virtctl
sudo pelagos build -f virtctl-jump.dockerfile -t 192.168.89.2:5004/kubevirt/virtctl-jump:v1.8.4-ssh .
sudo pelagos image push --insecure 192.168.89.2:5004/kubevirt/virtctl-jump:v1.8.4-ssh
```

Where `virtctl-jump.dockerfile` is:
```dockerfile
FROM 100.76.192.54:5000/library/alpine:3.20
RUN apk add --no-cache openssh-client
COPY virtctl /usr/local/bin/virtctl
```

## Gotchas

### CirrOS cloud-init does not handle `ssh_authorized_keys`

CirrOS ships a minimal reimplementation of cloud-init, not the full package. It parses
`#cloud-config` but only supports a tiny subset of modules — `final_message` and a few
others. The `ssh_authorized_keys` directive requires the `users_groups` and
`ssh_authkey_fingerprints` modules from the full cloud-init package, which CirrOS
doesn't include. The block is silently ignored.

This is by design: CirrOS is a smoke-test image, not a general-purpose cloud image.
A real cloud image (Ubuntu cloud, Fedora cloud) handles `ssh_authorized_keys` correctly
and the manual key injection step would not be needed.

### Dropbear v2018.76 requires legacy RSA auth

CirrOS's SSH server is Dropbear v2018.76 (2018). Modern OpenSSH disabled `ssh-rsa`
(SHA1-based RSA signatures) by default because SHA1 is deprecated. Dropbear 2018 only
speaks `ssh-rsa`; it does not support the newer `rsa-sha2-256` / `rsa-sha2-512`
variants that modern OpenSSH prefers.

Result: ed25519 keys are silently rejected, and RSA keys fail unless you explicitly
re-enable the legacy algorithm:

```
-o PubkeyAcceptedAlgorithms=+ssh-rsa
```

This is already set in `jump-job.yaml` via `virtctl`'s `-t` (local-ssh-opts) flag.
In production you would use a modern cloud image with a current OpenSSH server.

### RBAC: portforward requires both `get` and `create`

The KubeVirt portforward subresource requires the `get` verb in addition to `create`
(despite the API call being a POST). Both are in the Role.
