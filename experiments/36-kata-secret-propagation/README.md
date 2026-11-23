# Experiment 36 — Does a rotated Secret reach a running Kata pod?

Settles the Kata half of the Secret-propagation question in
`docs/hosted-control-plane-isolation.md` (experiment 35 did KubeVirt). The cluster has no
Kata, so the test builds one: a throwaway KubeVirt VM on ipc8 (nested virtualization,
`host-passthrough`) runs a single-node k3s with Kata Containers 4.4.0 installed, and a Kata
pod and a runc control pod mount the same Secret.

## How it works

`run-test.sh` (from omen) applies `vmi.yaml` with `cloud-init.yaml` as user data. The guest
script `kata-test.sh` then, entirely inside the guest:

1. mounts a data disk, downloads the Kata static release, installs k3s (with cluster and
   service CIDRs that do not overlap the outer cluster) and a `kata` RuntimeClass
   (runtime-rs shim, QEMU config);
2. creates a CA and two leaf certificates (A, B), a Secret holding A, and two pods running
   `probe.py` — one `runtimeClassName: kata`, one default (runc);
3. waits until both show A through the file and through two local TLS services
   (`svc_static` loads once, `svc_dyn` reloads per handshake), checks the Kata pod has its
   own kernel and a virtiofs mount, then replaces the Secret with B and times each source.

Progress and results are printed to the guest console (`KT:` lines), which `run-test.sh`
follows. `teardown.sh` removes the namespace. The guest accepts the caller's SSH public key
(`~/.ssh/id_rsa.pub`, override with `SSH_PUBKEY_FILE`) for debugging.

## Result (one run, Kata 4.4.0 runtime-rs + QEMU, k3s v1.37.2, KubeVirt v1.8.4)

| Source | Kata pod | runc pod |
|--------|----------|----------|
| Secret volume file | 57 s | 76 s |
| Service reloading per handshake | 57 s | 76 s |
| Service loading once | never (needs a restart) | never |

The Kata pod ran kernel 6.18.62 against the guest's 6.8.0 and mounted `/certs` as virtiofs,
so it was a real microVM.

## Caveats

- **One run**, 3 s resolution. The 57 versus 76 s gap is within the kubelet's sync jitter; the
  fair reading is "Kata added no measurable delay", not "Kata is faster".
- **runtime-rs only.** The 4.4.0 static tarball ships the Rust shim and no Go shim.
- **Nested virtualization** (Kata inside a KubeVirt guest); absolute timings on bare metal
  may differ.
- **Stock containerd in the guest**, not Pelagos. This says nothing about Kata under Pelagos.
- The Kata agent's own poll interval is not isolated; the kubelet sync dominates.
- Not tested: Secrets over the inotify limit (8 files or 1 MB), the real control plane
  components reloading certificates.
