#!/usr/bin/env bash
# Nightly 9pm: silence alerts, gracefully drain and shut down cluster, cut Kasa power.
set -euo pipefail

echo "==> [$(date)] cluster night-off starting"

echo "==> Silencing alerts until 05:30..."
/scripts/silence-alerts.sh night 05:30

echo "==> Shutting down cluster..."
/scripts/shutdown-cluster.sh

echo "==> Waiting 60s for nodes to fully power off..."
sleep 60

echo "==> Cutting Kasa power to all nodes..."
python3 /scripts/cluster-kasa-outlet.py off all

echo "==> [$(date)] Done. Cluster is off. Alerts resume at 05:30."
