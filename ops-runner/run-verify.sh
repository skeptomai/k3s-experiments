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

# The default pelagos0 bridge has NO LAN egress; the observability stack's
# bridge does (that's how prometheus reaches the ipc nodes). Reuse it — the
# non-default pelagos network (the 10.90.1.0/24 monitoring bridge).
NET="$("$PELAGOS" network ls 2>/dev/null | awk 'NR>1 && $1!="pelagos0" && $1!="" {print $1; exit}')"
[[ -n "$NET" ]] || { echo "ERROR: no egress pelagos network found (need the monitoring bridge for LAN access)" >&2; exit 1; }

# Persist the run: a timestamped host dir holds the per-experiment logs AND the
# full stdout — journald rate-limits the rapid PASS/FAIL lines into oblivion, so
# the journal/exit-code alone isn't a readable record.
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$BASE/logs/$STAMP"
mkdir -p "$RUN_DIR"
ln -sfn "$RUN_DIR" "$BASE/logs/latest"

echo "--- running verify-experiments (network $NET, logs -> $RUN_DIR) ---"
"$PELAGOS" run --rm --name verify-runner \
    --network "$NET" \
    -e VERIFY_ONLAN=1 \
    -e REPO=/repo \
    -e LOGDIR=/logs \
    --bind-ro "$SSH_DIR:/root/.ssh" \
    --bind    "$REPO_DIR:/repo" \
    --bind    "$RUN_DIR:/logs" \
    -w /repo \
    "$IMAGE" \
    bash scripts/verify-experiments.sh 2>&1 | tee "$RUN_DIR/run.log"
rc=${PIPESTATUS[0]}
echo "verify-runner exit=$rc  (0 = all passed)  —  $RUN_DIR/run.log"
exit $rc
