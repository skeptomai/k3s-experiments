#!/usr/bin/env bash
# Morning 5am: power on all cluster nodes, wait for Ready, then uncordon.
# Alerts resume at 05:30 automatically (silence set at 9pm expires then).
#
# ERR trap + `set -e` = any unhandled failure fires a Pushover alert before
# the script exits (added 2026-08-16 alongside the night-off.sh fix for the
# same underlying gap: a failed scheduler run had no way to tell anyone).
# The two `until` loops below previously had no bounded timeout at all --
# a genuinely stuck API server or node would just retry every 15s forever
# with no alert, rather than failing loudly. Both are now capped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSHOVER="$SCRIPT_DIR/pushover-alert.sh"

on_error() {
    local exit_code=$? line=$1
    "$PUSHOVER" "morning-on: SCRIPT FAILED" \
        "morning-on.sh exited with status $exit_code at line $line. Cluster may not be fully powered on / nodes may still be cordoned. Check manually: kubectl get nodes, and consider re-running scripts/cluster-scheduler/morning-on.sh from omen."
}
trap 'on_error $LINENO' ERR

export KUBECONFIG=/etc/cluster-scheduler/kubeconfig

ALL_NODES="ipc4 ipc5 ipc6 ipc7 ipc8 ipc9"

echo "==> [$(date)] cluster morning-on starting"
echo "==> Powering on all cluster nodes..."
python3 /scripts/cluster-kasa-outlet.py on all || echo "WARN: Kasa outlet unreachable — nodes may already be up, continuing"

echo "==> [$(date)] Waiting for API server to become reachable..."
API_WAIT_MAX=40   # 40 * 15s = 10 minutes
api_wait_count=0
until kubectl get nodes --request-timeout=5s >/dev/null 2>&1; do
    api_wait_count=$((api_wait_count + 1))
    if [ "$api_wait_count" -ge "$API_WAIT_MAX" ]; then
        echo "ERROR: API server still unreachable after 10 minutes" >&2
        exit 1
    fi
    echo "    API server not ready yet, retrying in 15s..."
    sleep 15
done
echo "    API server is up."

echo ""
echo "==> Waiting for all 6 nodes to be Ready..."
NODES_WAIT_MAX=40   # 40 * 15s = 10 minutes
nodes_wait_count=0
until [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -eq 6 ]; do
    READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
    nodes_wait_count=$((nodes_wait_count + 1))
    if [ "$nodes_wait_count" -ge "$NODES_WAIT_MAX" ]; then
        echo "ERROR: only $READY/6 nodes Ready after 10 minutes" >&2
        exit 1
    fi
    echo "    $READY/6 nodes Ready, retrying in 15s..."
    sleep 15
done
echo "    All 6 nodes Ready."

echo ""
echo "==> Uncordoning all nodes..."
for node in $ALL_NODES; do
    echo "    uncordoning $node"
    kubectl uncordon "$node"
done

echo ""
echo "==> Recycling SPIRE agent pods to force fresh bootstrap bundle fetch..."
# SPIRE CA rotates every ~12h. Agent pod objects persist across power cycles and the
# init container (which fetches the trust bundle) only runs once per pod creation.
# After one or more CA rotations, the stale bootstrap bundle causes TLS handshake
# failure on reconnect. Deleting pods here is cheap: init container takes <30s.
#
# --wait=false is required, not optional: `kubectl delete` blocks by default
# until the pod is confirmed gone, and the spire-agent DaemonSet pod on
# aws-graviton-build (stopped between build sessions) can NEVER confirm
# termination -- its kubelet is unreachable while the node is off. Without
# this flag the delete hung forever every morning the AWS node was stopped,
# leaving the whole script (and its --rm container on nazgul) stuck
# indefinitely -- discovered 2026-08-28 as 4 days' worth of never-exited
# morning-on.sh containers piled up on nazgul. The SPIRE_READY retry loop
# below already handles partial availability correctly (a stopped AWS node
# means 5/6, not 6/6, which is expected and already produces a warning, not
# a hard failure) -- deleting async here doesn't change that behavior at all.
kubectl delete pods -n spire -l app=spire-agent --ignore-not-found --wait=false
echo "    Waiting for SPIRE agents to re-attest..."
# Bounded retry instead of one fixed sleep+check: ipc8/ipc9 use Infineon SLB9672
# TPMs, which have been observed taking up to ~70s for CreatePrimary during
# attestation (vs. Nuvoton on ipc4-7) -- a single 45s check produced false-positive
# alerts for a transient, still-converging state.
SPIRE_WAIT_MAX=12   # 12 * 15s = 3 minutes
spire_wait_count=0
SPIRE_READY=0
until [ "$SPIRE_READY" -eq 6 ]; do
    SPIRE_READY=$(kubectl get pods -n spire -l app=spire-agent --no-headers 2>/dev/null | grep -c "1/1" || true)
    [ "$SPIRE_READY" -eq 6 ] && break
    spire_wait_count=$((spire_wait_count + 1))
    if [ "$spire_wait_count" -ge "$SPIRE_WAIT_MAX" ]; then
        break
    fi
    echo "    $SPIRE_READY/6 SPIRE agents Ready, retrying in 15s..."
    sleep 15
done
echo "    $SPIRE_READY/6 SPIRE agents Ready"
if [ "$SPIRE_READY" -lt 6 ]; then
    "$PUSHOVER" "morning-on: SPIRE agents incomplete" \
        "Only $SPIRE_READY/6 SPIRE agents Ready after 3 minutes of retrying post-recycle. Cluster is otherwise up. Check: kubectl get pods -n spire -l app=spire-agent -o wide"
fi

echo ""
echo "==> [$(date)] Done. Cluster is up and scheduling. Alerts resume at 05:30."
