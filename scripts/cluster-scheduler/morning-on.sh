#!/usr/bin/env bash
# Morning 5am: power on all cluster nodes. Alerts resume at 05:30 automatically.
set -euo pipefail

echo "==> [$(date)] cluster morning-on starting"
echo "==> Powering on all cluster nodes..."
python3 /scripts/cluster-kasa-outlet.py on all

echo "==> [$(date)] Done. k3s will start automatically. Alerts resume at 05:30."
