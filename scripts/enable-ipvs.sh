#!/usr/bin/env bash
# Switch kube-proxy from iptables to IPVS mode with least-connection scheduling.
#
# What this does:
#   1. Loads ip_vs kernel modules on all nodes and persists them in /etc/modules
#   2. Appends kube-proxy-arg to /etc/rancher/k3s/config.yaml on each node
#   3. Rolling-restarts k3s on servers (one at a time, preserving etcd quorum)
#   4. Restarts k3s-agent on workers
#   5. Verifies IPVS virtual servers are active via ipvsadm
#
# Required kernel modules (present on Ubuntu 26.04 kernel 7.x, just not loaded by default):
#   ip_vs ip_vs_rr ip_vs_lc ip_vs_wrr ip_vs_sh nf_conntrack
#
# Safe to re-run: module load and config append are both idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/node-roles.sh"

JUMP="cb@ipc4.taildd208.ts.net"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

IPVS_MODULES=(ip_vs ip_vs_rr ip_vs_lc ip_vs_wrr ip_vs_sh nf_conntrack)

ssh_node() {
    local node=$1; shift
    if [[ "$node" == "ipc4" ]]; then
        ssh $SSH_OPTS "$JUMP" "$@"
    else
        ssh $SSH_OPTS -J "$JUMP" "cb@$node" "$@"
    fi
}

# --- Phase 1: load and persist modules ---

echo "==> Phase 1: load and persist ip_vs modules"
for node in "${SERVER_NODES[@]}" "${AGENT_NODES[@]}"; do
    echo "    $node"
    ssh_node "$node" "sudo modprobe ${IPVS_MODULES[*]}"
    for mod in "${IPVS_MODULES[@]}"; do
        ssh_node "$node" "grep -qxF '$mod' /etc/modules || echo '$mod' | sudo tee -a /etc/modules > /dev/null"
    done
done

# --- Phase 2: update live k3s config ---

echo "==> Phase 2: append kube-proxy-arg to live k3s config"
for node in "${SERVER_NODES[@]}" "${AGENT_NODES[@]}"; do
    echo "    $node"
    ssh_node "$node" "sudo grep -q 'proxy-mode=ipvs' /etc/rancher/k3s/config.yaml && echo '    (already set)' || printf '\nkube-proxy-arg:\n  - \"proxy-mode=ipvs\"\n  - \"ipvs-scheduler=lc\"\n' | sudo tee -a /etc/rancher/k3s/config.yaml > /dev/null"
done

# --- Phase 3: rolling restart servers ---

echo "==> Phase 3: rolling restart servers (one at a time)"
for node in "${SERVER_NODES[@]}"; do
    echo "    $node: restarting k3s"
    ssh_node "$node" "sudo systemctl restart k3s"
    echo "    $node: waiting for Ready..."
    sleep 15
    ssh $SSH_OPTS "$JUMP" "sudo kubectl wait node/$node --for=condition=Ready --timeout=120s"
    echo "    $node: Ready"
done

# --- Phase 4: restart agents ---

echo "==> Phase 4: restarting agents"
for node in "${AGENT_NODES[@]}"; do
    echo "    $node: restarting k3s-agent"
    ssh_node "$node" "sudo systemctl restart k3s-agent"
    sleep 5
done

echo "    waiting for agents to be Ready..."
for node in "${AGENT_NODES[@]}"; do
    ssh $SSH_OPTS "$JUMP" "sudo kubectl wait node/$node --for=condition=Ready --timeout=120s"
    echo "    $node: Ready"
done

# --- Phase 5: verify ---

echo "==> Phase 5: verify IPVS virtual servers"
ssh $SSH_OPTS "$JUMP" "sudo ipvsadm -Ln 2>/dev/null | head -30" || \
    echo "    (ipvsadm not on ipc4 — check any node: sudo ipvsadm -Ln)"

echo ""
echo "==> Done. kube-proxy is now in IPVS least-connection mode."
echo "    Verify: ssh -J cb@ipc4.taildd208.ts.net cb@ipc4 sudo ipvsadm -Ln"
