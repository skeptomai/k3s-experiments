#!/usr/bin/env bash
# One-time setup for the nazgul LAN-side ops runner. Run ON nazgul (as root).
#
#   ssh root@nazgul 'bash -s' < ops-runner/setup-nazgul.sh
#
# Creates a dedicated nazgul-ops SSH key + ssh config, clones this repo, builds
# the Pelagos ops image, and prints the PUBLIC KEY to authorize on the nodes.
# Idempotent: re-running won't clobber an existing key.
set -euo pipefail

BASE="${OPS_RUNNER_BASE:-/mnt/primary_storage/ops-runner}"
SSH_DIR="$BASE/ssh"
REPO_DIR="$BASE/k3s-experiments"
REPO_URL="${OPS_RUNNER_REPO_URL:-https://github.com/skeptomai/k3s-experiments.git}"
PELAGOS="${PELAGOS_BIN:-pelagos}"

mkdir -p "$SSH_DIR" && chmod 700 "$BASE" "$SSH_DIR"

# Dedicated key (revocable, scoped to the runner — NOT cb@omen's key).
if [[ ! -f "$SSH_DIR/id_rsa" ]]; then
    ssh-keygen -t ed25519 -N '' -C 'nazgul-ops@verify-runner' -f "$SSH_DIR/id_rsa"
fi
chmod 600 "$SSH_DIR/id_rsa"

# ssh config: ephemeral known_hosts (no stale-key failures after node reinstalls),
# always use this key. Mounted read-only into the container at /root/.ssh.
cat > "$SSH_DIR/config" <<'EOF'
Host *
  IdentityFile /root/.ssh/id_rsa
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking accept-new
  ConnectTimeout 10
EOF
chmod 600 "$SSH_DIR/config"

# Repo (kept current by run-verify.sh's git pull).
if [[ ! -d "$REPO_DIR/.git" ]]; then
    git clone "$REPO_URL" "$REPO_DIR"
else
    git -C "$REPO_DIR" pull --ff-only || true
fi

# Build the ops image.
if ! "$PELAGOS" image ls 2>/dev/null | grep -q 'k3s-ops-runner'; then
    "$PELAGOS" build -t k3s-ops-runner:latest -f "$REPO_DIR/ops-runner/Dockerfile" "$REPO_DIR/ops-runner"
fi

echo
echo "=== nazgul-ops setup done. Authorize this PUBLIC KEY on the nodes (cb user): ==="
cat "$SSH_DIR/id_rsa.pub"
echo "==============================================================================="
echo "Add it to each node's ~cb/.ssh/authorized_keys and the autoinstall"
echo "ssh.authorized-keys (so reinstalls keep it). Then: bash run-verify.sh"
