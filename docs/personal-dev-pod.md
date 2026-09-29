# Personal Dev Pod

A persistent, Tailscale-reachable SSH dev environment running on the
cluster: `ssh cb@devbox.taildd208.ts.net`. Built for a month of travel with
one laptop (Mac, arm64) — edit locally, build/test as real x86_64 Linux on
the cluster, without SSHing directly into a shared physical node (ipc4-9)
or entangling this cluster's shared infrastructure.

## Why this exists

The editing side of "local-edit/remote-build" was already solved: native
Doom Emacs locally (no network latency), and for Linux-only Rust projects
the cross-target rust-analyzer setup documented in
`dotfiles/doomemacs/doom/RUST_LSP_CROSS_TARGET.md`. What was missing was a
stable place to actually compile/run/test as x86_64 Linux that survives a
month unattended if the cluster needs to reschedule or recover something —
hence a dedicated pod (Deployment + PVC + Service), not ad hoc SSH access
to a physical node.

## Architecture

- **Namespace**: `personal-dev-pod`, matching the one-namespace-per-app
  convention used by `postgres-pgvector`, `jupyter`, etc.
- **Compute**: a single-replica `Deployment`,
  `nodeSelector: node-class=fastest` (the ipc7-9 pool) — not pinned to a
  specific node, so the scheduler can place/reschedule it onto whichever
  worker has room. Modest resources (`requests: 1 CPU/2Gi`,
  `limits: 4 CPU/8Gi`) — see "Resource contention" below.
- **Storage**: a 100Gi PVC, `storageClassName: nfs` (nazgul-backed, via
  `manifests/nfs-subdir-provisioner`), mounted at `/home/cb` so git
  checkouts, `target/` build output, and shell state all survive pod
  reschedule/restart regardless of which node it lands on
  (`docs/kamaji-on-k3s.md:103`). `manifests/postgres-pgvector/storage.yaml`
  deliberately avoids `nfs` because of NFS locking semantics that matter
  for a database's byte-range locking on its data directory/WAL — that
  doesn't apply to a plain home directory, so `nfs` is the right choice
  here.
- **Image**: `dev-pod/Dockerfile`, based on `rust:1-bookworm` (same base
  proven in `pelagos/docs/k8s-build/builder.Dockerfile`). Adds
  `openssh-server` (pubkey-only, no password/root login — see
  `dev-pod/sshd_config`), a non-root `cb` user, and the general toolchain
  (git, build-essential, curl; rustup/cargo/rustc come from the base
  image). Entry point is `dev-pod/entrypoint.sh` → `sshd -D`, the first
  long-running (not Job-style/one-shot) container pattern in this repo.
- **Network**: `manifests/personal-dev-pod/service.yaml` is a plain
  `v1/Service` with `tailscale.com/expose: "true"` +
  `tailscale.com/hostname: "devbox"`, the exact pattern proven by
  `manifests/postgres-pgvector/service.yaml` — the Tailscale operator
  proxies whatever port is declared (here 22), not just HTTP.
- **Auth**: a Secret (`personal-dev-pod-ssh-key`, created manually,
  **not** committed to git — same handling as
  `experiments/29-pelagos-build`'s `pelagos-build-ssh-key`) holding the
  owner's public key, mounted read-only and copied into
  `/home/cb/.ssh/authorized_keys` by `entrypoint.sh` on every container
  start (see "SSH permissions" below for why it's copied rather than
  mounted directly).
- **Flux-managed**: everything under `manifests/personal-dev-pod/` is
  wired into its own Flux `Kustomization`
  (`clusters/ipc/personal-dev-pod.yaml`), same as every other real app
  here. If the pod, PVC, or its node ever need recreating while the owner
  is unreachable, Flux reconciles it back automatically. The container
  image itself is the one piece Flux can't produce — see Bootstrap below.

## Bootstrap mechanics

1. **Build the image for x86_64** and push it to the cluster's local Zot
   registry (`192.168.89.2:5004`, the same one `pelagos-builder` uses).
   The cluster nodes are x86_64 but a workstation may be arm64 (Mac), so
   the build runs *on* a cluster node rather than cross-compiling locally:
   ```
   rsync -av dev-pod/ cb@ipc4.taildd208.ts.net:/tmp/personal-dev-pod-build/
   ssh cb@ipc4.taildd208.ts.net 'cd /tmp/personal-dev-pod-build && \
     pelagos build -f Dockerfile -t 192.168.89.2:5004/personal-dev-pod:latest --network host . && \
     pelagos image push --insecure 192.168.89.2:5004/personal-dev-pod:latest'
   ```
   ipc4 already has `pelagos` installed and a working route to the
   registry (this is exactly the mechanism `scripts/cluster-scheduler/build-job.yaml`
   automates as an in-cluster Job for its own image; done here as a
   one-off SSH build since it's a single manual bootstrap step, not a
   repeatable pipeline).
2. **Create the SSH-pubkey Secret** (manual, out-of-band, not in git):
   ```
   kubectl create secret generic personal-dev-pod-ssh-key -n personal-dev-pod --from-file=authorized_keys=$HOME/.ssh/Omen.pub
   ```
3. **Push manifests to GitHub and reconcile Flux**:
   ```
   git add dev-pod/ manifests/personal-dev-pod/ clusters/ipc/personal-dev-pod.yaml scripts/sync-to-devpod.sh docs/personal-dev-pod.md && git commit -m "..." && git push
   kubectl annotate kustomization -n flux-system flux-system reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
   ```
   (Flux reconciles `manifests/` from GitHub, not local `kubectl apply` —
   see this repo's top-level `CLAUDE.md`.)

## Usage

- **Connect**: `ssh cb@devbox.taildd208.ts.net` — works from anywhere on
  the tailnet, including while traveling, no port-forwarding or router
  changes needed.
- **Fast iterate**: `scripts/sync-to-devpod.sh <local-dir> [remote-subdir]`
  rsyncs a local working tree to `~/<remote-subdir>/` on the pod without
  needing a git commit per intermediate state — the actual "local edit,
  remote build" loop, avoiding TRAMP's per-operation SSH round-trip
  latency for routine read/write/build cycles.
- **Deliberate snapshots**: plain `git push`/`pull` on the pod, same as
  always.
- **Bonus**: this pod can also serve as a remote-LSP target over TRAMP for
  a project that doesn't have a local cross-target rust-analyzer config
  yet — same infrastructure covers both workflows, use whichever fits a
  given project.

## Known gotchas

### SSH permissions (the most likely rough edge)

sshd's `StrictModes` rejects a login if the home directory or
`~/.ssh` is group/other-writable, or if `authorized_keys` isn't owned by
the user or root. Two things make this non-trivial here:

- Secret-mounted files come in root-owned with the volume's `defaultMode`
  (0644 here) — fine permission-wise (not group/other-writable), but not
  owned by `cb`, and a `subPath` mount doesn't pick up Secret updates
  live.
- On first NFS provisioning, `nfs-subdir-provisioner` creates the PVC's
  backing directory without knowing the pod's eventual uid in advance,
  so it can come up wide-open.

Both are fixed by `dev-pod/entrypoint.sh`, which runs as root (sshd needs
root for privilege separation anyway) on every container start: it copies
the pubkey from the Secret mount into `/home/cb/.ssh/authorized_keys`,
then `chown`s/`chmod`s the home dir (750, non-recursive — it can hold a
large `target/`/cargo tree after real builds) and `.ssh/` (700,
recursive but small) explicitly, rather than relying on the volume mount
alone. **This was tested end-to-end after first deploy, not assumed** —
see Verification below.

SSH host keys have the same "generated once, must persist" concern for a
different reason (avoiding host-key-changed warnings on every reschedule,
not StrictModes): they're generated into a PVC subPath
(`.ssh-host-keys`, via the `home` PVC mounted a second time at
`/etc/ssh/host_keys`) the first time the pod starts, and reused after
that.

### rust-analyzer not included in rust:1-bookworm by default

`rustup component add rust-analyzer` is required explicitly — `rust:1-bookworm`'s
default toolchain (cargo/rustc) doesn't include it. Without this, `rust-analyzer`
on `PATH` is just rustup's dispatch proxy stub, which errors
(`Unknown binary 'rust-analyzer' in official toolchain...`) on every
invocation instead of running a server. In an Emacs/rustic-mode (or any
lsp-mode/eglot) client, that reads as the LSP server continuously
crashing/restarting rather than a missing-install problem — confirmed
2026-09-29 on exactly this symptom. Fixed in `dev-pod/Dockerfile` (baked
into the image now, verified on a freshly-recreated pod, not just
live-patched).

### Resource contention with the pelagos build Job

`experiments/29-pelagos-build/build-job.yaml` pins a pelagos build Job
specifically to ipc7, requesting up to 12 CPU/16Gi at burst. The dev
pod's own footprint is kept modest (`requests: 1 CPU/2Gi`,
`limits: 4 CPU/8Gi`) so idle SSH access costs little and an occasional
overlap just slows a build rather than starving anything. No measured
per-node headroom baseline exists in this repo — this sizing is a
reasonable starting estimate, not a measured one; revisit if it's ever
tight in practice.

## Verification

Performed after first deploy (2026-09-29):

- `kubectl get pods -n personal-dev-pod -l app=personal-dev-pod` → `1/1
  Running`.
- `ssh cb@devbox.taildd208.ts.net echo ok` → succeeded from omen, proving
  both the Tailscale exposure and the authorized_keys mount actually
  work.
- PVC reschedulability: wrote a marker file, deleted the pod (Deployment
  recreated it, landing on a different node), confirmed the marker file
  survived.
- Real build: synced a small test project to the pod via
  `scripts/sync-to-devpod.sh` and ran `cargo build`, confirming a genuine
  x86_64 Linux toolchain.
