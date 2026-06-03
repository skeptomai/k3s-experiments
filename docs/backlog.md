# Infrastructure Backlog

## Serial Console

**Status**: Hardware ready, not yet configured. Blocked on: physical serial cables.

All three ipc nodes have 16550A UART on ttyS0 (0x3f8, IRQ 4, 115200 baud). Neither
GRUB nor systemd is configured to use it.

**When cables are available:**
- Edit `/etc/default/grub` on each node, add to `GRUB_CMDLINE_LINUX`:
  `console=tty0 console=ttyS0,115200n8`
- Run `sudo update-grub`
- Enable getty: `sudo systemctl enable --now serial-getty@ttyS0.service`
- Write `scripts/enable-serial-console.sh` to do this across all three nodes at once

This gives both normal display and serial console simultaneously. Essential recovery
path if a node loses network after a botched config change.

---

## PXE Boot Server (Raspberry Pi)

**Status**: Not started. Hardware available: Pi 3B+.

**Goal**: Wipe and reinstall any ipc node from scratch via network boot, without
touching the router's core DHCP config.

**Architecture**:
- Pi 3B+ on 192.168.88.x (same subnet as ipc nodes)
- OS: Raspberry Pi OS Lite 64-bit, headless, static IP
- dnsmasq in proxy mode: intercepts PXE DHCP requests without conflicting with
  the router's DHCP server (router keeps handing out IPs)
- TFTP: serves netboot files (grubnetx64.efi for UEFI, pxelinux.0 for BIOS)
- nginx: serves Ubuntu autoinstall configs (subiquity cloud-init YAML)
  matched by MAC address per node

**Per-node autoinstall config** covers: partition layout, packages, SSH keys,
and post-install steps to rejoin the ipc node to k3s as a worker.

**Steps when ready**:
1. Image Pi with Raspberry Pi OS Lite 64-bit
2. Set static IP on 192.168.88.x, enable SSH
3. Install dnsmasq, tftpd-hpa (or use dnsmasq's built-in TFTP), nginx
4. Configure dnsmasq as DHCP proxy with TFTP root pointing at netboot files
5. Download Ubuntu 24.04 netboot files into TFTP root
6. Write per-node autoinstall YAML files (one per MAC address)
7. Configure nginx to serve autoinstall configs
8. Test: set an ipc node to network-boot first in BIOS, power cycle it

---

## Ideas / Future Experiments

- **Enforcing CNI (Cilium or Calico)** — flannel+wireguard-native does not enforce
  NetworkPolicy. Experiment 09 manifests are correct and will work once the CNI is
  swapped. Cilium is the natural choice — also enables Hubble observability and
  eBPF-based dataplane.
- **Upgrade existing experiments** to use NFS StorageClass now that it's the default
  (experiment 04 uses local-path PVs manually — could be simplified)
- **Monitoring stack**: Prometheus + Grafana via Helm (repos already added on ipc1)
- **Cert-manager**: automatic TLS for ingress resources
- **Longhorn**: alternative distributed block storage (compare to NFS)
- **GitOps**: ArgoCD or Flux for deploying experiments from this repo automatically

### SPIRE hardening

- **SPIRE Controller Manager** — replace `demo-registration-job.yaml` with
  `ClusterSPIFFEID` CRDs managed by the [SPIRE Controller Manager](https://github.com/spiffe/spire-controller-manager).
  Currently, registration entries live in SPIRE's internal SQLite database — Git captures
  the intent ("run this job") but not the outcome ("these entries exist"). If the server
  loses its PVC the entries are gone and the job must be re-run manually. With the
  controller manager, entries are declared as Kubernetes resources in Git and continuously
  reconciled into SPIRE — fully GitOps-compatible. Low priority while the cluster has one
  trust domain and a handful of workloads; becomes important as SPIRE expands.

### Natural progressions from experiment 11 (SPIRE)

- **mTLS with SPIRE SVIDs** — use the workload identity we now have to actually encrypt
  service-to-service traffic. Options: Envoy sidecar proxies, or a minimal Go demo that
  calls `spiffe-helper` / the SPIFFE Workload API directly. Closes the loop on SPIRE:
  identity → encryption.
- **OPA / Gatekeeper** — admission policy enforcement. Fits after RBAC (05) and pairs
  well with SPIRE (policy can reference SPIFFE IDs).
- **Horizontal Pod Autoscaler** — builds on resource limits (06). Requires metrics-server
  (not currently installed). Scale a deployment under synthetic load.
- **Flux image automation** — Flux is already running for cluster bootstrap; a proper
  experiment could cover ImageRepository + ImagePolicy + ImageUpdateAutomation to show
  automated rollout when a new container image is pushed.
  **Prerequisite**: requires a workload image we actually build and own. Needs a companion
  app (trivial Go/Python HTTP server) with a GitHub Actions workflow that builds and pushes
  to ghcr.io on each commit. Flux watches the registry, not the source repo.
  **Access model**: Flux needs write access to *this repo* (`k3s-experiments`) to commit
  image tag bumps to deployment manifests — not to the application source repo. Plan: Flux
  writes to a `flux-updates` branch, `main` is branch-protected. Merges to `main` are
  manual — cb reviews the PR before deploying. Can automate later once the pipeline is
  trusted. The full experiment is really
  "CI/CD end-to-end": source push → image build → registry → Flux detects → manifest
  commit → reconcile → deploy.
