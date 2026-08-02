#!/bin/bash
# Switch kube-proxy from IPVS to nftables mode on all 6 nodes.
# IPVS conflicts with Cilium's BPF service hooks — NodePorts are unreachable from
# outside the cluster when both are active. nftables mode does not have this conflict.
#
# Rolling restart: ipc5 → ipc6 → ipc4 (preserves etcd quorum), then ipc7-9 in parallel.
# Safe to run on a live cluster.

set -euo pipefail

SERVERS=(ipc5 ipc6 ipc4)
AGENTS=(ipc7 ipc8 ipc9)
JUMP="cb@ipc4.taildd208.ts.net"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

deploy_and_restart() {
    local node="$1"
    local config_src="$2"
    echo "==> $node: deploying config and restarting k3s"
    if [ "$node" = "ipc4" ]; then
        ssh $SSH_OPTS "$JUMP" "sudo cp /dev/stdin /etc/rancher/k3s/config.yaml" < "$config_src"
        ssh $SSH_OPTS "$JUMP" "sudo systemctl restart k3s"
    else
        ssh $SSH_OPTS -J "$JUMP" "cb@$node" "sudo cp /dev/stdin /etc/rancher/k3s/config.yaml" < "$config_src"
        ssh $SSH_OPTS -J "$JUMP" "cb@$node" "sudo systemctl restart k3s"
    fi
}

wait_node_ready() {
    local node="$1"
    echo -n "    waiting for $node to be Ready"
    for i in $(seq 1 30); do
        sleep 5
        STATUS=$(ssh $SSH_OPTS "$JUMP" "sudo kubectl get node $node --no-headers 2>/dev/null | awk '{print \$2}'" 2>/dev/null || true)
        if [ "$STATUS" = "Ready" ]; then
            echo " — Ready"
            return 0
        fi
        echo -n "."
    done
    echo " — TIMEOUT"
    return 1
}

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_CONFIG="$REPO/config/k3s-server.yaml"
SERVER_JOIN_CONFIG="$REPO/config/k3s-server-join.yaml"
AGENT_CONFIG="$REPO/config/k3s-agent.yaml"

echo "Rolling kube-proxy to nftables mode"
echo "  servers (rolling): ${SERVERS[*]}"
echo "  agents  (parallel): ${AGENTS[*]}"
echo

# --- Control plane: rolling ---
for node in "${SERVERS[@]}"; do
    cfg="$SERVER_JOIN_CONFIG"
    [ "$node" = "ipc4" ] && cfg="$SERVER_CONFIG"
    deploy_and_restart "$node" "$cfg"
    wait_node_ready "$node"
done

# --- Agents: push configs in parallel, restart, wait ---
echo "==> agents: deploying configs"
for node in "${AGENTS[@]}"; do
    ssh $SSH_OPTS -J "$JUMP" "cb@$node" "sudo cp /dev/stdin /etc/rancher/k3s/config.yaml" < "$AGENT_CONFIG" &
done
wait

echo "==> agents: restarting k3s"
for node in "${AGENTS[@]}"; do
    ssh $SSH_OPTS -J "$JUMP" "cb@$node" "sudo systemctl restart k3s" &
done
wait

for node in "${AGENTS[@]}"; do
    wait_node_ready "$node"
done

echo
echo "==> verifying NodePort (node-exporter :30900 on ipc4)"
sleep 3
if curl -s --max-time 5 http://192.168.88.55:30900/metrics | grep -q 'node_uname_info'; then
    echo "    NodePort working — node-exporter metrics reachable"
else
    echo "    WARNING: NodePort still unreachable — check nftables rules on ipc4"
fi

echo
echo "Done. Run /check-cluster-health to confirm all nodes Ready."
