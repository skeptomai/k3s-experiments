#!/usr/bin/env bash
# Nightly 9pm: silence alerts, gracefully drain and shut down cluster, cut Kasa power.
#
# Deliberately does NOT use `set -e` at the top level. 2026-08-15: a failure
# in the alert-silencing step silently aborted the entire run before it ever
# reached shutdown-cluster.sh -- the fleet just stayed up all night with no
# indication anything was wrong. Each step below is now checked explicitly:
# a failure to silence alerts is a real problem (you'll get spurious alerts
# during the drain) but should NOT block the actual shutdown, which matters
# far more. A failure in shutdown-cluster.sh itself is the one that must be
# loud, since it means nodes may still be drawing power / not drained.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSHOVER="$SCRIPT_DIR/pushover-alert.sh"

echo "==> [$(date)] cluster night-off starting"

echo "==> Silencing alerts until 05:30..."
if ! "$SCRIPT_DIR/silence-alerts.sh" night 05:30; then
    echo "WARNING: failed to silence alerts — proceeding with shutdown anyway" >&2
    "$PUSHOVER" "night-off: alert-silence failed" \
        "silence-alerts.sh could not reach Alertmanager. Proceeding with cluster shutdown anyway (more important than avoiding spurious alerts during drain) — expect alert noise during tonight's shutdown. Check Alertmanager/monitoring stack: pelagos ps on nazgul."
fi

echo "==> Shutting down cluster..."
if ! "$SCRIPT_DIR/shutdown-cluster.sh"; then
    echo "ERROR: shutdown-cluster.sh failed — cluster may be partially drained/cordoned, nodes may still be up" >&2
    "$PUSHOVER" "night-off: SHUTDOWN FAILED" \
        "shutdown-cluster.sh exited with an error. Cluster may be left in a partially-cordoned/drained state with nodes still powered on. Needs manual attention: check node status and re-run scripts/shutdown-cluster.sh from omen if needed."
    # Don't cut Kasa power if the graceful shutdown didn't complete —
    # yanking power on nodes that never got `shutdown -h now` risks
    # filesystem corruption, unlike the intended clean poweroff path.
    exit 1
fi

echo "==> Waiting 60s for nodes to fully power off..."
sleep 60

echo "==> Cutting Kasa power to all nodes..."
if ! python3 "$SCRIPT_DIR/cluster-kasa-outlet.py" off all; then
    echo "WARNING: failed to cut Kasa power to all nodes" >&2
    "$PUSHOVER" "night-off: Kasa power-off failed" \
        "cluster-kasa-outlet.py off all did not complete successfully. Nodes were sent a clean shutdown but outlet power may still be on for one or more nodes — check manually."
fi

echo "==> [$(date)] Done. Cluster is off. Alerts resume at 05:30."
