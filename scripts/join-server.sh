#!/usr/bin/env bash
# Join a node to the cluster as an additional control-plane SERVER (etcd member).
#
# Topology-driven: the etcd seed / token source is CLUSTER_INIT_NODE and IPs come
# from node-maps.sh, so this works for ANY topology (not hardcoded to ipc1). The
# joining server's config (config/k3s-server-join.yaml) sets `server:` to the
# kube-vip VIP, so it registers against the HA endpoint, not a single node.
#
# Observed install (2026-07-04): k3s v1.35.5+k3s1 via get.k3s.io (INSTALL_K3S_EXEC=
# server), pelagos CRI, config in /etc/rancher/k3s/config.yaml. Reached over the
# tailnet (ssh <node> resolves to <node>.taildd208.ts.net via ~/.ssh/config).
#
# IMPORTANT: a server join needs the seed's SERVER token AND a config.yaml carrying
# `server:` + `token:` BEFORE the k3s install runs — without `server:` the installer
# would cluster-init a NEW etcd instead of joining.
#
# Usage: scripts/join-server.sh <node>   (a SERVER_NODES member other than the seed)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/node-roles.sh"
source "$REPO_ROOT/scripts/lib/node-maps.sh"

node="${1:-}"
if [[ -z "$node" ]] || ! is_server_node "$node" || [[ "$node" == "$CLUSTER_INIT_NODE" ]]; then
    echo "Usage: $0 <node>   (joining control-plane servers only; not the etcd seed $CLUSTER_INIT_NODE)" >&2
    echo "  SERVER_NODES: ${SERVER_NODES[*]}" >&2
    exit 1
fi
[[ -n "${NODE_IP[$node]:-}" ]] || { echo "ERROR: unknown node '$node'" >&2; exit 1; }

SEED="$CLUSTER_INIT_NODE"
echo "=== join-server: $node -> cluster (seed/token source: $SEED) ==="

echo "--- pin k3s version to the seed + fetch the join token ---"
VER=$(ssh -o StrictHostKeyChecking=no "cb@$SEED" 'k3s --version' | awk 'NR==1{print $3}')
TOKEN=$(ssh -o StrictHostKeyChecking=no "cb@$SEED" 'sudo cat /var/lib/rancher/k3s/server/token')
echo "  version: $VER"

echo "--- clear any stale node object + node-password secret for $node ---"
ssh -o StrictHostKeyChecking=no "cb@$SEED" "
    sudo k3s kubectl delete node $node --ignore-not-found
    sudo k3s kubectl -n kube-system delete secret ${node}.node-password.k3s --ignore-not-found"

echo "--- uninstall any prior k3s/k3s-agent on $node, write server-join config, install k3s SERVER ---"
# Config (token injected) is base64-encoded and passed as an ARGUMENT — do NOT pipe
# data to `ssh "bash -s" <<HEREDOC`: the heredoc wins stdin, so the pipe gets SIGPIPE.
CFG_B64=$(grep -vE '^\s*#' "$REPO_ROOT/config/k3s-server-join.yaml" \
    | sed "s|<INJECTED_AT_INSTALL_FROM_SEED_TOKEN>|${TOKEN}|" | base64 -w0)
ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=10 "cb@$node" "set -e
  sudo systemctl is-active pelagos-cri >/dev/null 2>&1 || { echo 'ERROR: pelagos-cri not active — run install-pelagos.sh first'; exit 1; }
  if [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then sudo /usr/local/bin/k3s-agent-uninstall.sh >/dev/null 2>&1; \
  elif [ -x /usr/local/bin/k3s-uninstall.sh ]; then sudo /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1; fi
  sudo mkdir -p /etc/rancher/k3s
  echo '$CFG_B64' | base64 -d | sudo tee /etc/rancher/k3s/config.yaml >/dev/null
  sudo chmod 600 /etc/rancher/k3s/config.yaml
  echo \"config written (server line: \$(sudo grep -c '^server:' /etc/rancher/k3s/config.yaml), token line: \$(sudo grep -c '^token:' /etc/rancher/k3s/config.yaml))\"
  curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION='$VER' INSTALL_K3S_EXEC=server sh -"

echo "--- reconcile Pelagos CRI + role config on $node ---"
"$REPO_ROOT/scripts/install-pelagos.sh" "$node"

echo "=== $node joined as control-plane server ==="
ssh -o StrictHostKeyChecking=no "cb@$SEED" "sudo k3s kubectl get node $node -o wide"
