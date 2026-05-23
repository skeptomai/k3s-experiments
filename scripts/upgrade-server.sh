#!/usr/bin/env bash
# Upgrades the k3s server (control plane) on ipc1.
# Run from any machine with SSH access to ipc1 via the tailnet.
#
# Usage: ./upgrade-server.sh [channel]
#   channel: k3s release channel, e.g. v1.32, v1.33, stable (default: stable)
set -euo pipefail

CHANNEL="${1:-stable}"
SERVER="ipc1.taildd208.ts.net"

echo "=== Upgrading k3s server on $SERVER to channel $CHANNEL ==="
ssh -o StrictHostKeyChecking=no cb@"$SERVER" \
    "curl -sfL https://get.k3s.io | sudo INSTALL_K3S_CHANNEL=$CHANNEL sh -"

echo ""
echo "=== Node status ==="
ssh -o StrictHostKeyChecking=no cb@"$SERVER" "sudo kubectl get nodes"
