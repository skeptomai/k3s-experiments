#!/usr/bin/env bash
# Join a freshly-reinstalled control-plane node (ipc2 or ipc3) to ipc1's embedded
# etcd cluster as an additional k3s SERVER, then install the Pelagos CRI.
#
# This is the control-plane counterpart of upgrade-agents.sh (which joins worker
# nodes as agents). reinstall-nodes.sh dispatches to whichever matches the node's
# role (see scripts/lib/node-roles.sh). Background:
# docs/ipc1-3-control-plane-ha-runbook.md.
#
# IMPORTANT: a server join needs the seed's SERVER token (/var/lib/rancher/k3s/
# server/token) AND a config.yaml carrying `server:` + `token:` BEFORE the k3s
# install runs — without `server:` the installer would cluster-init a NEW etcd
# instead of joining. The k3s version is pinned to the seed's running version so
# the new etcd member never skews ahead of the cluster.
#
# Run from any machine with SSH to ipc1 via the tailnet (ipc2/ipc3 reached via
# the ipc1 jump). Usage: ./join-server.sh <ipc2|ipc3>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/node-roles.sh"

SERVER="ipc1.taildd208.ts.net"
declare -A NODE_IP=([ipc2]="192.168.88.52" [ipc3]="192.168.88.54")

node="${1:-}"
if [[ -z "$node" ]] || ! is_server_node "$node" || [[ "$node" == "$CLUSTER_INIT_NODE" ]]; then
    echo "Usage: $0 <ipc2|ipc3>  (joining control-plane servers only; not the etcd seed $CLUSTER_INIT_NODE)" >&2
    exit 1
fi

echo "=== Pinning k3s version to the etcd seed ($CLUSTER_INIT_NODE) ==="
VERSION=$(ssh -o StrictHostKeyChecking=no cb@"$SERVER" 'k3s --version' | awk 'NR==1{print $3}')
echo "  version: $VERSION"

echo "=== Fetching server token + clearing stale node state for $node ==="
TOKEN=$(ssh -o StrictHostKeyChecking=no cb@"$SERVER" 'sudo cat /var/lib/rancher/k3s/server/token')
ssh -o StrictHostKeyChecking=no cb@"$SERVER" "
    sudo kubectl delete node $node --ignore-not-found
    sudo kubectl -n kube-system delete secret ${node}.node-password.k3s --ignore-not-found"

echo "=== Writing server-join config + installing k3s SERVER on $node ==="
# Token is piped over stdin so it never appears in argv / process listings.
{ printf '%s\n' "$TOKEN"; sed "s|<INJECTED_AT_INSTALL_FROM_IPC1_TOKEN>|__TOKEN__|" \
    "$REPO_ROOT/config/k3s-server-join.yaml"; } \
  | ssh -o StrictHostKeyChecking=no -J cb@"$SERVER" cb@"${NODE_IP[$node]}" \
    "VER='$VERSION' bash -s" <<'REMOTE'
set -euo pipefail
T=$(head -n1)                       # first stdin line = token
CONFIG=$(cat | sed "s|__TOKEN__|${T}|")   # remaining lines = config template
sudo mkdir -p /etc/rancher/k3s
printf '%s\n' "$CONFIG" | sudo tee /etc/rancher/k3s/config.yaml >/dev/null
sudo chmod 600 /etc/rancher/k3s/config.yaml
echo "config written (token line present: $(sudo grep -c '^token:' /etc/rancher/k3s/config.yaml))"
curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION="$VER" INSTALL_K3S_EXEC=server sh -
REMOTE

echo "=== Installing Pelagos CRI on $node (role-aware: server config + k3s unit) ==="
"$REPO_ROOT/scripts/install-pelagos.sh" "$node"

echo "=== $node joined as control-plane server ==="
ssh -o StrictHostKeyChecking=no cb@"$SERVER" "sudo kubectl get node $node -o wide"
