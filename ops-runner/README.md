# ops-runner — LAN-side cluster tooling on nazgul (via Pelagos)

Runs cluster ops (currently `verify-experiments.sh`) **from nazgul** as a
**Pelagos container**, reaching the ipc nodes **directly over the LAN** — no
tailnet, no ProxyJump through ipc1. nazgul is always-on and LAN-resident, so
this removes both the coffee-shop latency and the single-jump-host chokepoint
that flaked the suite when run from omen.

Pelagos already runs nazgul's observability stack standalone (`pelagos run`,
no CRI) — this is the same proven pattern, just a one-shot job instead of
long-lived services.

## How it works
- **Image** (`Dockerfile`): tooling only — `openssh-client`, `python3`, `bash`,
  `git`, `rsync`. The repo and SSH key are **bind-mounted at run time**, never
  baked in, so the image is generic and the repo always current.
- **Key**: a dedicated `nazgul-ops` ed25519 key under `$BASE/ssh` (mounted
  read-only at `/root/.ssh`); its ssh `config` forces `UserKnownHostsFile
  /dev/null` so node reinstalls never cause host-key failures.
- **Direct SSH**: `run-verify.sh` sets `VERIFY_ONLAN=1`, which makes
  `verify-experiments.sh` reach ipc1 + nodes by LAN IP directly (no `-J ipc1`).
- **Base dir** `$BASE = /mnt/primary_storage/ops-runner` on nazgul:
  `ssh/` (key+config) and `k3s-experiments/` (the git clone).

## One-time setup (on nazgul)
```
ssh root@nazgul 'bash -s' < ops-runner/setup-nazgul.sh
```
Generates the key + config, clones the repo, builds the `k3s-ops-runner` image,
and prints the **public key**. Authorize it on every node (cb user):
- add it to each node's `~cb/.ssh/authorized_keys`, and
- add it to the autoinstall `ssh.authorized-keys` in
  `pxe/autoinstall/*/user-data` (so reinstalls keep it).

If the repo is private, set `OPS_RUNNER_REPO_URL` to an authenticated URL or add
a read-only deploy key on nazgul.

## Run it
```
ssh root@nazgul /mnt/primary_storage/ops-runner/k3s-experiments/ops-runner/run-verify.sh
```
`run-verify.sh` does `git pull`, builds the image if missing, then
`pelagos run --rm` the suite on-LAN.

## Schedule it (nightly)
```
# on nazgul:
cp ops-runner/verify-runner.{service,timer} /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now verify-runner.timer
```
Runs at 04:30 nightly; `journalctl -u verify-runner` for results.
