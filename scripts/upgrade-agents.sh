#!/usr/bin/env bash
# Upgrades the k3s agents (worker nodes) on ipc2 and ipc3.
# Run from any machine with SSH access to ipc1 via the tailnet (not from ipc1 itself).
# ipc2 and ipc3 are reached by jumping through ipc1.
#
# IMPORTANT: K3S_URL and K3S_TOKEN must always be passed explicitly when
# upgrading agents. Without them the install script has no way to know
# the node is an agent and will incorrectly install it as a server.
#
# Usage: ./upgrade-agents.sh [channel] [node...]
#   channel: k3s release channel, e.g. v1.32, v1.33, stable (default: stable)
#   node:    ipc2 | ipc3 | ipc4 | ipc5 (default: ipc2 ipc3; specify to target one node)
set -euo pipefail

declare -A NODE_IP=([ipc2]="192.168.88.52" [ipc3]="192.168.88.54" [ipc4]="192.168.88.55" [ipc5]="192.168.88.56")

CHANNEL="stable"
AGENTS=()
for arg in "$@"; do
    if [[ "$arg" == ipc* ]]; then
        AGENTS+=("$arg")
    else
        CHANNEL="$arg"
    fi
done
[[ ${#AGENTS[@]} -eq 0 ]] && AGENTS=(ipc2 ipc3)

SERVER="ipc1.taildd208.ts.net"
SERVER_URL="https://192.168.88.53:6443"

echo "=== Fetching cluster token from $SERVER ==="
TOKEN=$(ssh -o StrictHostKeyChecking=no cb@"$SERVER" \
    "sudo cat /var/lib/rancher/k3s/server/node-token")

for agent in "${AGENTS[@]}"; do
    echo ""
    echo "=== Clearing stale node password secret for $agent ==="
    ssh -o StrictHostKeyChecking=no cb@"$SERVER" \
        "sudo kubectl delete secret ${agent}.node-password.k3s -n kube-system 2>/dev/null && echo Deleted || echo 'Not present, skipping'"

    echo "=== Upgrading k3s agent on $agent to channel $CHANNEL ==="
    ssh -o StrictHostKeyChecking=no -J cb@"$SERVER" cb@"${NODE_IP[$agent]}" \
        "curl -sfL https://get.k3s.io | sudo K3S_URL=$SERVER_URL K3S_TOKEN=$TOKEN INSTALL_K3S_CHANNEL=$CHANNEL sh -"
    echo "Done: $agent"
done

echo ""
echo "=== Installing Pelagos CRI on agents ==="
"$(dirname "$0")/install-pelagos.sh" "${AGENTS[@]}"
