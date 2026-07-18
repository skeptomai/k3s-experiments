#!/usr/bin/env bash
# cluster-night-off.sh
# Nightly 9pm sequence: silence alerts, gracefully drain and shut down cluster,
# then cut Kasa power. Designed to run via systemd timer on omen.
#
# Silence expires at 05:30 automatically — alerts resume after the startup
# grace window without any 5am action needed on this side.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> [$(date)] cluster-night-off starting"

echo "==> Silencing alerts until 05:30..."
"$SCRIPT_DIR/silence-alerts.sh" night 05:30

echo "==> Shutting down cluster..."
"$SCRIPT_DIR/shutdown-cluster.sh"

echo "==> Waiting 60s for nodes to fully power off..."
sleep 60

echo "==> Cutting Kasa power to all nodes..."
"$SCRIPT_DIR/cluster-kasa-outlet.py" off all

echo "==> [$(date)] Done. Cluster is off. Alerts resume at 05:30."
