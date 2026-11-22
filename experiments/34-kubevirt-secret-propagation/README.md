# Experiment 34 — Does a rotated Secret reach a running KubeVirt guest?

Settles one open question from `docs/hosted-control-plane-isolation.md`: when a TLS Secret
is rotated, does a running KubeVirt guest see the new certificate, and does a service
pick it up? Uses a real X.509 chain (a CA and two leaf certificates, A then B), not
dummy data.

## How it works

One Secret (`tls-test`, holding `tls.crt`, `tls.key`, `ca.crt`) is attached to the same VMI
two ways:

- **`certdisk`**: as a `secret` volume delivered as an ISO disk.
- **`certfs`**: as a `secret` volume delivered as a virtiofs filesystem.

A probe inside the Ubuntu 24.04 guest prints, every 5 seconds to the serial console, the
SHA-256 fingerprint (first 8 hex digits) of the certificate seen through each path, plus
the certificate presented by two local TLS services that read the virtiofs mount:

- `svc_static` loads the certificate once at start (like software with no reload support).
- `svc_dyn` loads it again on every handshake (like software that reloads).

`run-test.sh` generates the certificates, applies the VMI with leaf A, waits for a baseline
where all four sources show A, replaces the Secret with leaf B, then records how long each
source takes to show B.

## Files

| File | Purpose |
|------|---------|
| `vmi.yaml` | VMI pinned to ipc8, with the Secret attached as disk and as virtiofs |
| `cloud-init.yaml` | Guest setup and the probe script (delivered as a Secret, since inline cloud-init is limited to 2048 bytes) |
| `run-test.sh` | Generates certificates, runs the rotation, prints the result table |
| `teardown.sh` | Deletes the throwaway namespace `kv-secret-test` |

## Run

```
bash experiments/34-kubevirt-secret-propagation/run-test.sh
```

Then `bash experiments/34-kubevirt-secret-propagation/teardown.sh`. Run with
`set -o pipefail` if piping the output, or a failure is hidden by the pipe.

## Result (one run, KubeVirt v1.8.4, no feature gates set)

| Source | Saw leaf B after |
|--------|------------------|
| Secret as ISO disk (`disk`) | never (watched 420 s) |
| Secret as virtiofs (`fs`) | 78 s |
| Service loading the cert once (`svc_static`) | never (needs a restart) |
| Service reloading per handshake (`svc_dyn`) | 78 s |

What it shows:

- A Secret delivered as a **disk never updates** in a running guest, matching the KubeVirt
  docs ("Secret update propagation is not supported").
- A Secret delivered as a **virtiofs filesystem does update**, with no restart and no
  feature gate set on this KubeVirt version.
- Whether a *service* picks up the new certificate is separate from delivery: the
  load-once service kept serving leaf A on the updated files.

## Caveats

- **One run.** The resolution is 5-10 s and nothing was repeated, so treat 78 s as an
  order of magnitude, not a precise figure.
- **The delay is mostly the kubelet.** The guest shares the launcher pod's Secret volume,
  and the kubelet only refreshes a Secret volume on its periodic sync. The same delay
  applies to any pod's Secret volume, so it is not a KubeVirt cost.
- **Not tested here:** Kata (this cluster has no Kata), live migration with a virtiofs
  Secret, and the real control plane components (kube-apiserver and others) reloading
  certificates on file change.
- The cluster's runtime is a custom CRI, which may influence what works. It worked here.
