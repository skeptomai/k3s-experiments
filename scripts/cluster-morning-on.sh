#!/usr/bin/env bash
# cluster-morning-on.sh
# Nightly 5am sequence: power on all cluster nodes via Kasa.
# k3s starts automatically as a systemd service on each node.
# Silence set at 9pm expires at 05:30, giving a 30-minute grace window
# for the cluster to fully come up before alerts resume.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> [$(date)] cluster-morning-on starting"
echo "==> Powering on all cluster nodes..."
"$SCRIPT_DIR/cluster-kasa-outlet.py" on all

echo "==> [$(date)] Done. k3s will start automatically. Alerts resume at 05:30."
