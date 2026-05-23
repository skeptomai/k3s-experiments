#!/usr/bin/env bash
# Upgrades the entire k3s cluster: server first, then agents.
# Run from any machine with SSH access to ipc1 via the tailnet.
#
# Usage: ./upgrade-cluster.sh [channel]
#   channel: k3s release channel, e.g. v1.32, v1.33, stable (default: stable)
set -euo pipefail

CHANNEL="${1:-stable}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Upgrading cluster to channel: $CHANNEL"
echo ""

bash "$SCRIPT_DIR/upgrade-server.sh" "$CHANNEL"
echo ""
bash "$SCRIPT_DIR/upgrade-agents.sh" "$CHANNEL"
