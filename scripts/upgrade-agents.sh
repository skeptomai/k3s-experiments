#!/usr/bin/env bash
# Upgrades the k3s agents (worker nodes) on ipc2 and ipc3.
# Run from any machine with SSH access to ipc1 via the tailnet.
# ipc2 and ipc3 are reached by jumping through ipc1.
#
# IMPORTANT: K3S_URL and K3S_TOKEN must always be passed explicitly when
# upgrading agents. Without them the install script has no way to know
# the node is an agent and will incorrectly install it as a server.
#
# Usage: ./upgrade-agents.sh [channel]
#   channel: k3s release channel, e.g. v1.32, v1.33, stable (default: stable)
set -euo pipefail

CHANNEL="${1:-stable}"
SERVER="ipc1.taildd208.ts.net"
SERVER_URL="https://192.168.88.53:6443"
AGENTS=(ipc2 ipc3)

echo "=== Fetching cluster token from $SERVER ==="
TOKEN=$(ssh -o StrictHostKeyChecking=no cb@"$SERVER" \
    "sudo cat /var/lib/rancher/k3s/server/node-token")

for agent in "${AGENTS[@]}"; do
    echo ""
    echo "=== Upgrading k3s agent on $agent to channel $CHANNEL ==="
    ssh -o StrictHostKeyChecking=no -J cb@"$SERVER" cb@"$agent" \
        "curl -sfL https://get.k3s.io | sudo K3S_URL=$SERVER_URL K3S_TOKEN=$TOKEN INSTALL_K3S_CHANNEL=$CHANNEL sh -"
    echo "Done: $agent"
done

echo ""
echo "=== Node status ==="
ssh -o StrictHostKeyChecking=no cb@"$SERVER" "sudo kubectl get nodes"
