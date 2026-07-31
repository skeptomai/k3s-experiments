# Experiment 26 — virtctl SSH jump from a container

`virtctl ssh` proxies SSH through the Kubernetes API via the `subresources.kubevirt.io/virtualmachineinstances/portforward` subresource — the same mechanism as `kubectl port-forward`. This experiment demonstrates that a pod inside the cluster can SSH into a KubeVirt VM with no direct network path to the VM, using only the in-cluster service account token for API authentication. It also surfaces a practical gotcha: CirrOS ships Dropbear v2018.76, which requires RSA keys and does not interoperate with modern OpenSSH's ed25519 auth path.

## Files

| File | Purpose |
|------|---------|
| `vmi-cirros-ssh.yaml` | CirrOS VMI pinned to ipc8, with a cloud-init stub that pre-installs an RSA public key |
| `rbac.yaml` | ServiceAccount `vm-jump`, Role granting `get` on VMIs and `get`/`create` on `virtualmachineinstances/portforward`, and RoleBinding |
| `ssh-keypair-secret.yaml` | Documents how to create the `vm-ssh-key` Secret; key not embedded (contains a private key) |
| `jump-job.yaml` | Job that runs `virtctl ssh` from inside the cluster to execute a command on the VMI |

## Setup

Generate an RSA 2048 keypair (RSA required — CirrOS Dropbear does not support ed25519):

```
ssh-keygen -t rsa -b 2048 -f /tmp/vm-ssh-rsa -N "" -C "vm-jump-experiment"
```

Create the Secret:

```
kubectl create secret generic vm-ssh-key --from-file=id_rsa=/tmp/vm-ssh-rsa
```

Patch the public key into `vmi-cirros-ssh.yaml` under `ssh_authorized_keys`, then apply RBAC and start the VMI:

```
kubectl apply -f experiments/26-virtctl-ssh-jump/rbac.yaml -f experiments/26-virtctl-ssh-jump/vmi-cirros-ssh.yaml
```

Wait for the VMI to reach `Running`:

```
kubectl get vmi cirros-ssh -w
```

## Container image

The jump container is Alpine + `virtctl` binary + `openssh-client`, pushed to the local registry:

```
192.168.89.2:5004/kubevirt/virtctl-jump:v1.8.4-ssh
```

To rebuild, download the `virtctl` binary and build inside a cluster job using Pelagos, then push:

```
sudo pelagos image push --insecure 192.168.89.2:5004/kubevirt/virtctl-jump:v1.8.4-ssh
```

## Apply

```
kubectl apply -f experiments/26-virtctl-ssh-jump/jump-job.yaml
```

## Observe

Check the job logs:

```
kubectl logs -l job-name=vm-ssh-jump
```

Expected output ends with `SSH-jump-success`. The connection goes: jump pod → Kubernetes API (`portforward` subresource) → virt-handler → VMI — no pod-to-VM direct routing needed.

To confirm the RBAC is doing real work, check what the `vm-jump` service account can do:

```
kubectl auth can-i create virtualmachineinstances/portforward --as=system:serviceaccount:default:vm-jump
```

## Gotcha: CirrOS cloud-init does not process `ssh_authorized_keys`

CirrOS uses a minimal cloud-init implementation that ignores the `ssh_authorized_keys` directive. If the public key is not already embedded in the VMI spec at creation time (via the `userData` field), you must inject it manually using the default CirrOS credentials (`cirros` / `gocubsgo`) over the pod network before the jump job will authenticate.

## Teardown

```
kubectl delete -f experiments/26-virtctl-ssh-jump/
kubectl delete secret vm-ssh-key
```
