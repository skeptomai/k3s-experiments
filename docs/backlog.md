# Infrastructure Backlog

## Cluster Hostname Rename

**Status**: Analyzed 2026-08-23, deferred — current names (ipc4-9) are staying.
Full analysis + step-by-step plan in
[`hostname-rename-plan.md`](hostname-rename-plan.md) if this comes up again.

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

## Secrets Management (External Secrets Operator + 1Password)

**Status**: Proposed 2026-09-20, not started — deliberately deferred, not a small
change. Triggered by a real incident: the `homelab-rag-secrets` Secret's
`openai-api-key` went stale when the key was rotated in 1Password, silently breaking
the `homelab-rag` service (HTTP 401 from OpenAI on every query) with no signal until
someone actually read a response body — see
[`orgfiles/home-network/homelab-rag.md`](../../orgfiles/home-network/homelab-rag.md)
("Known issues") for the full incident writeup.

**Problem**: every secret in this repo follows the same pattern — created once via a
bare `kubectl create secret` command, documented only as a comment in the owning
manifest, deliberately never committed to git (jupyter-token, open-webui's
bootstrap-admin, `authentik-secrets`, `authentik-postgresql`, `homelab-rag-secrets`,
`postgres-pgvector-password`, tailscale-operator's OAuth client, ...). This is
consistent and intentional (secrets don't belong in git), but it means **nothing
propagates a rotation** — if the underlying credential changes anywhere else (1Password,
an upstream API), the in-cluster Secret silently goes stale until something fails.

**Why not just SOPS-encrypted secrets in git**: that only solves "secret material isn't
plaintext in git," not the actual failure mode above — a SOPS-encrypted Secret still
needs a human to notice the rotation and manually re-encrypt + commit. Doesn't fix
anything.

**Proposed fix**: [External Secrets Operator](https://external-secrets.io/), backed by
a 1Password provider (Connect server or the 1Password SDK provider) — 1Password is
already the de facto source of truth for every credential in this homelab (Admin
Forgejo, Authentik automation token, OpenAI key, etc.). Git would declare *which*
1Password item/field backs each k8s Secret (an `ExternalSecret` resource, fully
GitOps-managed, safe to commit — it's just a reference, not a value); ESO polls
1Password and keeps the real Secret in sync automatically. Pair with
[Reloader](https://github.com/stakater/Reloader) (annotate the Deployment, no per-app
code needed) to auto-restart pods when their Secret's content actually changes, closing
the loop end-to-end: rotate in 1Password → propagates to the cluster → pod picks it up,
no manual step anywhere.

**Scope**: touches every out-of-band secret listed above, not just one — a real
migration, not a one-file fix. **Suggested approach when picked up**: pilot on
`homelab-rag-secrets` alone first (smallest blast radius, and it's the one that already
broke once), confirm the ESO+1Password+Reloader loop actually works end-to-end, then
roll the pattern out to the rest.

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
