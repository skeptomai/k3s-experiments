#!/usr/bin/env bash
# Run the verify-experiments suite from nazgul as a Pelagos container, reaching
# the cluster DIRECTLY over the LAN (no tailnet, no ProxyJump through ipc1).
#
# Lives on nazgul under $BASE; invoked on demand or by verify-runner.timer.
# Keeps the repo current (git pull), builds the image if missing, then
# `pelagos run --rm` the suite with the repo + the nazgul-ops SSH key mounted.
set -euo pipefail

BASE="${OPS_RUNNER_BASE:-/mnt/primary_storage/ops-runner}"
REPO_DIR="$BASE/k3s-experiments"
SSH_DIR="$BASE/ssh"                       # holds id_rsa (0600) + config (UserKnownHostsFile /dev/null)
IMAGE="k3s-ops-runner:latest"
PELAGOS="${PELAGOS_BIN:-pelagos}"

[[ -d "$REPO_DIR/.git" ]] || { echo "ERROR: repo not at $REPO_DIR — run setup-nazgul.sh first" >&2; exit 1; }
[[ -f "$SSH_DIR/id_rsa" ]] || { echo "ERROR: no key at $SSH_DIR/id_rsa — run setup-nazgul.sh first" >&2; exit 1; }

echo "--- updating repo ($REPO_DIR) ---"
git -C "$REPO_DIR" pull --ff-only

echo "--- ensuring image $IMAGE ---"
if ! "$PELAGOS" image ls 2>/dev/null | grep -q 'k3s-ops-runner'; then
    echo "  building $IMAGE..."
    "$PELAGOS" build -t "$IMAGE" -f "$REPO_DIR/ops-runner/Dockerfile" "$REPO_DIR/ops-runner"
fi

echo "--- running verify-experiments (on-LAN, direct to nodes) ---"
exec "$PELAGOS" run --rm --name verify-runner \
    -e VERIFY_ONLAN=1 \
    -e REPO=/repo \
    --bind-ro "$SSH_DIR:/root/.ssh" \
    --bind    "$REPO_DIR:/repo" \
    -w /repo \
    "$IMAGE" \
    bash scripts/verify-experiments.sh
