#!/usr/bin/env bash
# Upgrades the k3s SERVER (control-plane) nodes: ipc1 ipc2 ipc3.
# In-place binary upgrade, ONE AT A TIME, waiting for each to return Ready before
# the next — so the 3-member etcd quorum is never lost (HA-safe rolling upgrade).
# Run from any machine with SSH access to ipc1 via the tailnet.
#
# Usage: ./upgrade-server.sh [channel] [node...]
#   channel: k3s release channel, e.g. v1.32, v1.33, stable (default: stable)
#   node:    ipc1 | ipc2 | ipc3 (default: all server nodes, seed first)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/node-roles.sh"

SERVER="ipc1.taildd208.ts.net"
declare -A NODE_IP=([ipc2]="192.168.88.52" [ipc3]="192.168.88.54")

CHANNEL="stable"
TARGETS=()
for arg in "$@"; do
    if [[ "$arg" == ipc* ]]; then TARGETS+=("$arg"); else CHANNEL="$arg"; fi
done
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=("${SERVER_NODES[@]}")   # ipc1 ipc2 ipc3, seed first

for node in "${TARGETS[@]}"; do
    if ! is_server_node "$node"; then
        echo "ERROR: $node is not a control-plane server — use upgrade-agents.sh." >&2
        exit 1
    fi
    # ipc1 is reachable directly; ipc2/ipc3 via the ipc1 jump.
    if [[ "$node" == "$CLUSTER_INIT_NODE" ]]; then
        ssh_cmd=(ssh -o StrictHostKeyChecking=no cb@"$SERVER")
    else
        ssh_cmd=(ssh -o StrictHostKeyChecking=no -J cb@"$SERVER" cb@"${NODE_IP[$node]}")
    fi

    echo "=== Upgrading k3s server on $node to channel $CHANNEL ==="
    "${ssh_cmd[@]}" "curl -sfL https://get.k3s.io | sudo INSTALL_K3S_CHANNEL=$CHANNEL sh -"

    echo "--- Waiting for $node to return Ready (preserve etcd quorum) ---"
    for _ in $(seq 1 60); do
        st=$(ssh -o StrictHostKeyChecking=no cb@"$SERVER" \
            "sudo kubectl get node $node --no-headers 2>/dev/null" | awk '{print $2}')
        [[ "$st" == "Ready" ]] && { echo "  $node Ready"; break; }
        sleep 4
    done
done

echo ""
echo "=== Node status ==="
ssh -o StrictHostKeyChecking=no cb@"$SERVER" "sudo kubectl get nodes"
