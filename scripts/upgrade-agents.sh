#!/usr/bin/env bash
# Upgrades / (re)joins the k3s AGENT (worker) nodes: ipc7 ipc8 ipc9.
# Run from any machine with SSH access to ipc4 via the tailnet (not from ipc4 itself).
# Agents are reached by jumping through ipc4.
#
# IMPORTANT: K3S_URL and K3S_TOKEN must always be passed explicitly when
# joining agents. Without them the install script has no way to know
# the node is an agent and will incorrectly install it as a server.
#
# Control-plane nodes (ipc4/ipc5/ipc6) are NOT agents — they run servers.
# Use join-server.sh for ipc5/ipc6; this script refuses them. See
# scripts/lib/node-roles.sh for the role map.
#
# Usage: ./upgrade-agents.sh [channel] [node...]
#   channel: k3s release channel, e.g. v1.32, v1.33, stable (default: stable)
#   node:    ipc7 | ipc8 | ipc9 (default: all agent nodes; specify to target one)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/node-roles.sh"

declare -A NODE_IP=([ipc4]="192.168.88.55" [ipc5]="192.168.88.56" [ipc6]="192.168.88.57" [ipc7]="192.168.88.63" [ipc8]="192.168.88.64" [ipc9]="192.168.88.65")

CHANNEL="stable"
AGENTS=()
for arg in "$@"; do
    if [[ "$arg" == ipc* ]]; then
        AGENTS+=("$arg")
    else
        CHANNEL="$arg"
    fi
done
[[ ${#AGENTS[@]} -eq 0 ]] && AGENTS=("${AGENT_NODES[@]}")

# Guard: never install a control-plane server node as an agent.
for a in "${AGENTS[@]}"; do
    if is_server_node "$a"; then
        echo "ERROR: $a is a control-plane server — use scripts/join-server.sh, not upgrade-agents.sh." >&2
        exit 1
    fi
done

SERVER="ipc4.taildd208.ts.net"                 # a control-plane node (token source)
SERVER_URL="https://192.168.88.58:6443"        # kube-vip VIP (HA endpoint, not a single node)

echo "=== Fetching cluster token + version from $SERVER ==="
TOKEN=$(ssh -o StrictHostKeyChecking=no cb@"$SERVER" \
    "sudo cat /var/lib/rancher/k3s/server/node-token")
# Pin agents to the SERVER's k3s version. Agents must NOT run a newer minor than
# the server (version skew) — the `stable` channel could install a newer k3s and
# break the join. This overrides the channel arg (upgrade path = bump server first,
# then re-run this to match).
K3S_VERSION=$(ssh -o StrictHostKeyChecking=no cb@"$SERVER" "k3s --version | awk 'NR==1{print \$3}'")
echo "  pinning agents to $K3S_VERSION"

for agent in "${AGENTS[@]}"; do
    echo ""
    echo "=== Clearing stale node password secret for $agent ==="
    ssh -o StrictHostKeyChecking=no cb@"$SERVER" \
        "sudo kubectl delete secret ${agent}.node-password.k3s -n kube-system 2>/dev/null && echo Deleted || echo 'Not present, skipping'"

    echo "=== Installing/updating k3s agent on $agent → $K3S_VERSION ==="
    ssh -o StrictHostKeyChecking=no -J cb@"$SERVER" cb@"${NODE_IP[$agent]}" \
        "curl -sfL https://get.k3s.io | sudo K3S_URL=$SERVER_URL K3S_TOKEN=$TOKEN INSTALL_K3S_VERSION=$K3S_VERSION sh -"
    echo "Done: $agent"
done

echo ""
echo "=== Installing Pelagos CRI on agents ==="
"$(dirname "$0")/install-pelagos.sh" "${AGENTS[@]}"
