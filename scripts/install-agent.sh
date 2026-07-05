#!/usr/bin/env bash
# (Re)install a node as a k3s AGENT (worker) pointed at the HA VIP.
#
# Topology-driven single-node counterpart of upgrade-agents.sh. Token + version
# come from CLUSTER_INIT_NODE; the agent registers at the kube-vip VIP so it never
# depends on any single control-plane node. Observed install (2026-07-04): k3s
# v1.35.5+k3s1 via get.k3s.io (INSTALL_K3S_EXEC=agent), pelagos CRI, reached over
# the tailnet.
#
# Usage: scripts/install-agent.sh <node>   (an AGENT_NODES member)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/node-roles.sh"
source "$REPO_ROOT/scripts/lib/node-maps.sh"

node="${1:-}"
if [[ -z "$node" ]] || is_server_node "$node"; then
    echo "Usage: $0 <node>   (worker/agent nodes only — servers use join-server.sh)" >&2
    echo "  AGENT_NODES: ${AGENT_NODES[*]}" >&2
    exit 1
fi
[[ -n "${NODE_IP[$node]:-}" ]] || { echo "ERROR: unknown node '$node'" >&2; exit 1; }

SEED="$CLUSTER_INIT_NODE"
SERVER_URL="${K3S_SERVER_URL:-https://192.168.88.58:6443}"   # kube-vip VIP (HA endpoint)
echo "=== install-agent: $node -> $SERVER_URL (token source: $SEED) ==="

VER=$(ssh -o StrictHostKeyChecking=no "cb@$SEED" 'k3s --version' | awk 'NR==1{print $3}')
TOKEN=$(ssh -o StrictHostKeyChecking=no "cb@$SEED" 'sudo cat /var/lib/rancher/k3s/server/token')
echo "  version: $VER"

echo "--- clear stale node object + node-password secret for $node ---"
ssh -o StrictHostKeyChecking=no "cb@$SEED" "
    sudo k3s kubectl delete node $node --ignore-not-found
    sudo k3s kubectl -n kube-system delete secret ${node}.node-password.k3s --ignore-not-found"

echo "--- uninstall prior k3s/k3s-agent, write agent config, install k3s AGENT ---"
grep -vE '^\s*#' "$REPO_ROOT/config/k3s-agent.yaml" \
  | ssh -o StrictHostKeyChecking=no "cb@$node" "VER='$VER' URL='$SERVER_URL' TOKEN='$TOKEN' bash -s" <<'REMOTE'
set -euo pipefail
CONFIG=$(cat)
sudo systemctl is-active pelagos-cri >/dev/null 2>&1 || { echo "ERROR: pelagos-cri not active — run install-pelagos.sh first"; exit 1; }
if [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then sudo /usr/local/bin/k3s-agent-uninstall.sh; \
elif [ -x /usr/local/bin/k3s-uninstall.sh ]; then sudo /usr/local/bin/k3s-uninstall.sh; fi
sudo mkdir -p /etc/rancher/k3s
printf '%s\n' "$CONFIG" | sudo tee /etc/rancher/k3s/config.yaml >/dev/null
curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION="$VER" INSTALL_K3S_EXEC=agent K3S_URL="$URL" K3S_TOKEN="$TOKEN" sh -
REMOTE

echo "--- reconcile Pelagos CRI + role config on $node ---"
"$REPO_ROOT/scripts/install-pelagos.sh" "$node"

echo "=== $node joined as agent ==="
ssh -o StrictHostKeyChecking=no "cb@$SEED" "sudo k3s kubectl get node $node -o wide"
