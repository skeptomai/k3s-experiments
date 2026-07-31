#!/usr/bin/env bash
# Install Cilium as the cluster CNI, replacing Flannel.
#
# Prerequisites (already done before running this script):
#   - config/k3s-server.yaml and config/k3s-server-join.yaml have flannel-backend: none
#   - config/k3s-agent.yaml has no flannel config (agents never had one)
#   - Helm 3 is available on omen
#
# What this script does:
#   1. Deploy updated k3s configs to all 6 nodes
#   2. Add the Cilium Helm repo
#   3. Install Cilium 1.19.x into namespace 'cilium' with k3s-specific values
#   4. Rolling-restart k3s servers (ipc4→ipc5→ipc6, 90s gap each) then agents
#   5. Wait for Cilium DaemonSet to be fully Ready
#   6. Print cilium status

set -euo pipefail

CILIUM_VERSION="1.19.6"
JUMP="cb@ipc4.taildd208.ts.net"
SERVERS=(ipc4 ipc5 ipc6)
AGENTS=(ipc7 ipc8 ipc9)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/node-roles.sh
source "$SCRIPT_DIR/lib/node-roles.sh"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

ssh_node() {
    local node="$1"; shift
    if [[ "$node" == "ipc4" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$JUMP" "$@"
    else
        ssh -o BatchMode=yes -o ConnectTimeout=15 -J "$JUMP" "cb@$node" "$@"
    fi
}

scp_node() {
    local src="$1" node="$2" dst="$3"
    if [[ "$node" == "ipc4" ]]; then
        scp -o BatchMode=yes "$src" "${JUMP}:${dst}"
    else
        scp -o BatchMode=yes -o ProxyJump="$JUMP" "$src" "cb@${node}:${dst}"
    fi
}

# ── Step 1: Deploy updated k3s configs ─────────────────────────────────────

log "Step 1: deploying updated k3s configs to all nodes"

for node in "${SERVERS[@]}"; do
    log "  deploying config to $node"
    if [[ "$node" == "ipc4" ]]; then
        scp_node "$REPO_ROOT/config/k3s-server.yaml" "$node" "/tmp/k3s-config.yaml"
    else
        # Inject token for joining servers
        TOKEN=$(ssh_node ipc4 "sudo cat /var/lib/rancher/k3s/server/token")
        sed "s|<INJECTED_AT_INSTALL_FROM_SEED_TOKEN>|${TOKEN}|g" \
            "$REPO_ROOT/config/k3s-server-join.yaml" > /tmp/k3s-join-config.yaml
        scp_node "/tmp/k3s-join-config.yaml" "$node" "/tmp/k3s-config.yaml"
        rm -f /tmp/k3s-join-config.yaml
    fi
    ssh_node "$node" "sudo cp /tmp/k3s-config.yaml /etc/rancher/k3s/config.yaml && sudo chmod 600 /etc/rancher/k3s/config.yaml"
done

for node in "${AGENTS[@]}"; do
    log "  deploying agent config to $node"
    scp_node "$REPO_ROOT/config/k3s-agent.yaml" "$node" "/tmp/k3s-config.yaml"
    ssh_node "$node" "sudo cp /tmp/k3s-config.yaml /etc/rancher/k3s/config.yaml && sudo chmod 600 /etc/rancher/k3s/config.yaml"
done

log "k3s configs deployed"

# ── Step 2: Add Cilium Helm repo ────────────────────────────────────────────

log "Step 2: setting up Cilium Helm repo"
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update cilium
log "Helm repo ready"

# ── Step 3: Install Cilium ──────────────────────────────────────────────────

log "Step 3: installing Cilium ${CILIUM_VERSION}"

# Pull the k3s API endpoint from the kubeconfig context (ipc4 direct, not VIP)
K8S_HOST="ipc4.taildd208.ts.net"
K8S_PORT="6443"

helm upgrade --install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace cilium \
    --create-namespace \
    --set cni.confDir=/var/lib/rancher/k3s/agent/etc/cni/net.d \
    --set cni.binPath=/var/lib/rancher/k3s/data/current/bin \
    --set cni.exclusive=true \
    --set "ipam.operator.clusterPoolIPv4PodCIDRList={10.42.0.0/16}" \
    --set kubeProxyReplacement=false \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set operator.replicas=2 \
    --set k8sServiceHost="${K8S_HOST}" \
    --set k8sServicePort="${K8S_PORT}" \
    --wait --timeout=5m

log "Cilium installed"

# ── Step 4: Rolling restart k3s (servers then agents) ───────────────────────

log "Step 4: rolling restart k3s to switch CNI (Flannel → Cilium)"
log "  WARNING: pod networking will be disrupted during restarts"

for node in "${SERVERS[@]}"; do
    log "  restarting k3s on $node (server)"
    ssh_node "$node" "sudo systemctl restart k3s"
    log "  waiting 90s for $node to rejoin etcd before proceeding"
    sleep 90
    # Verify node is Ready
    deadline=$((SECONDS + 120))
    while true; do
        status=$(ssh_node ipc4 "sudo kubectl get node $node --no-headers 2>/dev/null | awk '{print \$2}'")
        if [[ "$status" == "Ready" ]]; then
            log "  $node is Ready"
            break
        fi
        if [[ $SECONDS -ge $deadline ]]; then
            die "$node did not become Ready within 2 minutes after restart — check manually"
        fi
        sleep 5
    done
done

for node in "${AGENTS[@]}"; do
    log "  restarting k3s-agent on $node"
    ssh_node "$node" "sudo systemctl restart k3s-agent"
    sleep 15
done

log "All k3s restarts done"

# ── Step 5: Wait for Cilium DaemonSet ───────────────────────────────────────

log "Step 5: waiting for Cilium DaemonSet to be fully Ready"
kubectl rollout status daemonset/cilium -n cilium --timeout=5m

# Check operator too
kubectl rollout status deployment/cilium-operator -n cilium --timeout=3m

log "Cilium DaemonSet ready"

# ── Step 6: Status ───────────────────────────────────────────────────────────

log "Step 6: cilium status"
ssh_node ipc4 "cilium status 2>/dev/null" || \
    kubectl exec -n cilium ds/cilium -- cilium status 2>/dev/null || \
    log "  (cilium CLI not on ipc4 — check: kubectl exec -n cilium ds/cilium -- cilium status)"

log ""
log "═══════════════════════════════════════════════════"
log "Cilium ${CILIUM_VERSION} migration complete"
log "Verify:"
log "  kubectl get nodes"
log "  kubectl get pods -n cilium"
log "  kubectl exec -n cilium ds/cilium -- cilium status"
log "  bash experiments/09-network-policies/... to test NetworkPolicy enforcement"
log "═══════════════════════════════════════════════════"
