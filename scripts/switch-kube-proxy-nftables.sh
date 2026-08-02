#!/bin/bash
# Switch kube-proxy from IPVS to nftables mode on all 6 nodes.
# IPVS conflicts with Cilium's BPF service hooks — NodePorts are unreachable from
# outside the cluster when both are active. nftables mode does not have this conflict.
#
# Patches kube-proxy-arg IN PLACE in each node's live config, preserving all other
# fields (including the cluster token on join nodes). Rolling restart: ipc5 → ipc6 →
# ipc4 (preserves etcd quorum), then ipc7-9 in parallel.

set -euo pipefail

SERVERS=(ipc5 ipc6 ipc4)
AGENTS=(ipc7 ipc8 ipc9)
JUMP="cb@ipc4.taildd208.ts.net"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

# Replace the kube-proxy-arg block in /etc/rancher/k3s/config.yaml in place.
# Removes any existing kube-proxy-arg entries, appends the nftables one.
PATCH='import sys, re
cfg = open("/etc/rancher/k3s/config.yaml").read()
# Remove existing kube-proxy-arg block (key + indented list items)
cfg = re.sub(r"kube-proxy-arg:\n(?:  - [^\n]+\n)*", "", cfg)
# Append new block
cfg = cfg.rstrip("\n") + "\nkube-proxy-arg:\n  - \"proxy-mode=nftables\"\n"
open("/etc/rancher/k3s/config.yaml", "w").write(cfg)
print("patched")
'

patch_node() {
    local node="$1"
    echo "==> $node: patching kube-proxy-arg"
    if [ "$node" = "ipc4" ]; then
        ssh $SSH_OPTS "$JUMP" "sudo python3 -c '$PATCH'"
        ssh $SSH_OPTS "$JUMP" "sudo systemctl restart k3s"
    else
        ssh $SSH_OPTS -J "$JUMP" "cb@$node" "sudo python3 -c '$PATCH'"
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

echo "Rolling kube-proxy to nftables mode"
echo "  servers (rolling): ${SERVERS[*]}"
echo "  agents  (parallel): ${AGENTS[*]}"
echo

# --- Control plane: rolling ---
for node in "${SERVERS[@]}"; do
    patch_node "$node"
    wait_node_ready "$node"
done

# --- Agents: patch and restart in parallel ---
echo "==> agents: patching configs"
for node in "${AGENTS[@]}"; do
    ssh $SSH_OPTS -J "$JUMP" "cb@$node" "sudo python3 -c '$PATCH'" &
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
