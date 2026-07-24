#!/usr/bin/env bash
# Build Pelagos from a local source tree and deploy to ipc nodes.
#
# Builds release binaries on omen (x86_64, same arch as cluster), SCPs them to
# each node, stops pelagos-cri, replaces the binaries, and restarts the service
# + k3s. Intended for dev/testing builds that haven't been released yet.
#
# Usage: ./scripts/install-pelagos-local-build.sh [--src DIR] [node...]
#   --src DIR: path to pelagos source tree (default: ~/Projects/pelagos)
#   node: ipc4 | ipc5 | ipc6 | ipc7 | ipc8 | ipc9 (default: all six)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="ipc4.taildd208.ts.net"
source "$REPO_ROOT/scripts/lib/node-roles.sh"
DEFAULT_NODES=(ipc4 ipc5 ipc6 ipc7 ipc8 ipc9)
declare -A NODE_IP=([ipc4]="" [ipc5]="192.168.88.56" [ipc6]="192.168.88.57" [ipc7]="192.168.88.63" [ipc8]="192.168.88.64" [ipc9]="192.168.88.65")

SRC_DIR="$HOME/Projects/pelagos"
NODES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --src) SRC_DIR="$2"; shift 2 ;;
        *) NODES+=("$1"); shift ;;
    esac
done
[[ ${#NODES[@]} -eq 0 ]] && NODES=("${DEFAULT_NODES[@]}")

echo "=== Building Pelagos (release) from $SRC_DIR ==="
(cd "$SRC_DIR" && cargo build --release 2>&1)

PELAGOS_BIN="$SRC_DIR/target/release/pelagos"
PELAGOS_CRI_BIN="$SRC_DIR/target/release/pelagos-cri"
VERSION=$("$PELAGOS_BIN" --version 2>/dev/null || echo "unknown")
echo "Built: $VERSION"

deploy_node() {
    local node=$1
    local ssh_cmd scp_cmd svc

    if [ "$node" = "ipc4" ]; then
        ssh_cmd="ssh -o StrictHostKeyChecking=no cb@$SERVER"
        scp_cmd="scp -o StrictHostKeyChecking=no"
        scp_dst="cb@$SERVER"
    else
        local ip="${NODE_IP[$node]}"
        ssh_cmd="ssh -o StrictHostKeyChecking=no -J cb@$SERVER cb@$ip"
        scp_cmd="scp -o StrictHostKeyChecking=no -J cb@$SERVER"
        scp_dst="cb@$ip"
    fi
    svc=$(k3s_service "$node")

    echo ""
    echo "=== Deploying to $node ($svc) ==="

    # SCP binaries to /tmp on the node
    $scp_cmd "$PELAGOS_BIN" "$PELAGOS_CRI_BIN" "$scp_dst:/tmp/"

    # Install and restart
    $ssh_cmd bash -s "$svc" <<'REMOTE'
set -euo pipefail
K3S_SERVICE=$1

echo "--- Installing binaries ---"
sudo install -m 755 /tmp/pelagos     /usr/local/bin/pelagos
sudo install -m 755 /tmp/pelagos-cri /usr/local/bin/pelagos-cri
rm -f /tmp/pelagos /tmp/pelagos-cri

echo "--- Restarting pelagos-cri ---"
sudo systemctl restart pelagos-cri
sleep 3
sudo systemctl is-active pelagos-cri

echo "--- Restarting $K3S_SERVICE ---"
sudo systemctl restart "$K3S_SERVICE"

pelagos --version
echo "Done"
REMOTE

    echo "Done: $node"
}

# Deploy to all nodes in parallel
pids=()
for node in "${NODES[@]}"; do
    deploy_node "$node" &
    pids+=($!)
done

# Wait for all, collect failures
fail=0
for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
        echo "FAILED: ${NODES[$i]}"
        fail=$((fail+1))
    fi
done

echo ""
echo "=== Node status ==="
sleep 15
ssh -o StrictHostKeyChecking=no cb@"$SERVER" "sudo kubectl get nodes -o wide"

[[ $fail -eq 0 ]] && echo "All nodes updated." || { echo "$fail node(s) failed."; exit 1; }
