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
#   2. Pre-run cilium-sysctlfix on all nodes (workaround for pelagos#476-adjacent env var bug)
#   3. Mount bpffs at /run/cilium/bpf on all nodes (workaround for pelagos#477)
#   4. Add the Cilium Helm repo
#   5. Install Cilium 1.19.x into namespace 'cilium' with k3s-specific values
#   6. Rolling-restart k3s servers (ipc4→ipc5→ipc6, 90s gap each) then agents
#   7. Remove leftover Flannel interfaces (flannel-wg, cni0) from all nodes
#   8. Wait for Cilium DaemonSet to be fully Ready
#   9. Print cilium status
#
# KNOWN PELAGOS WORKAROUNDS (remove when fixed):
#   sysctlfix.enabled=false   — pelagos#476-adjacent: env vars missing in init container bash
#   bpf.autoMount.enabled=false + bpf.root=/run/cilium/bpf — pelagos#477: double /sys/fs/bpf mount
#   l7Proxy=false             — pelagos#478: /var/run hostPath mounted read-only
#
# CRITICAL: bpf.root=/run/cilium/bpf is NOT persistent across reboots. After any node
# reboot, Cilium will fail to start until pelagos#477 is fixed. The pre-mount step
# below re-applies it, but requires this script to be re-run after reboots.
#
# CRITICAL: Pod-to-pod networking requires pelagos#476 (CNI_ARGS missing pod metadata).
# Until that is fixed, all pods receive reserved:init identity and cannot communicate.

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

log "Step 2: pre-running cilium-sysctlfix on all nodes (workaround: pelagos#476-adjacent)"
# Cilium's apply-sysctl-overwrites init container can't run inside Pelagos because
# env vars are not visible in init container bash scripts. Run the sysctl fix from
# the host instead. Remove this step when pelagos#476 is resolved and sysctlfix.enabled=true.
for node in "${SERVERS[@]}" "${AGENTS[@]}"; do
    log "  sysctl fix on $node"
    # cilium-sysctlfix may not exist yet on first install; skip if absent
    ssh_node "$node" "test -f /var/lib/rancher/k3s/data/current/bin/cilium-sysctlfix && \
        sudo nsenter --mount=/proc/1/ns/mnt /var/lib/rancher/k3s/data/current/bin/cilium-sysctlfix || \
        log '  cilium-sysctlfix not found yet (first install) — will run again after Cilium is deployed'"
done

log "Step 3: mounting bpffs at /run/cilium/bpf on all nodes (workaround: pelagos#477)"
# Pelagos creates a double mount for /sys/fs/bpf inside containers. Using a non-sysfs
# path avoids the collision. NOT persistent: re-run this script after any node reboot
# until pelagos#477 is fixed and bpf.autoMount.enabled=true / bpf.root=/sys/fs/bpf can be used.
for node in "${SERVERS[@]}" "${AGENTS[@]}"; do
    log "  mounting /run/cilium/bpf on $node"
    ssh_node "$node" "sudo mkdir -p /run/cilium/bpf && \
        mountpoint -q /run/cilium/bpf || \
        sudo mount -t bpf bpf /run/cilium/bpf --make-shared"
done

log "Step 4: setting up Cilium Helm repo"
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update cilium
log "Helm repo ready"

# ── Step 5: Install Cilium ──────────────────────────────────────────────────

log "Step 5: installing Cilium ${CILIUM_VERSION}"

# k8sServiceHost must be an IP reachable from inside pods — Tailscale names are
# host-only and not resolvable from pod network namespaces. Use the kube-vip VIP.
K8S_HOST="192.168.88.58"
K8S_PORT="6443"

helm upgrade --install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace cilium \
    --create-namespace \
    --set cni.confPath=/var/lib/rancher/k3s/agent/etc/cni/net.d \
    --set cni.binPath=/var/lib/rancher/k3s/data/current/bin \
    --set cni.exclusive=true \
    --set "ipam.operator.clusterPoolIPv4PodCIDRList={10.42.0.0/16}" \
    --set kubeProxyReplacement=false \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set bpf.autoMount.enabled=false \
    --set bpf.root=/run/cilium/bpf \
    --set l7Proxy=false \
    --set sysctlfix.enabled=false \
    --set operator.replicas=2 \
    --set k8sServiceHost="${K8S_HOST}" \
    --set k8sServicePort="${K8S_PORT}" \
    --timeout=5m

log "Cilium installed"

# ── Step 6: Rolling restart k3s (servers then agents) ───────────────────────

log "Step 6: rolling restart k3s to switch CNI (Flannel → Cilium)"
log "  WARNING: pod networking will be disrupted during restarts"

for node in "${SERVERS[@]}"; do
    log "  restarting k3s on $node (server)"
    ssh_node "$node" "sudo systemctl restart k3s"
    log "  waiting for $node to rejoin etcd (up to 3 min)"
    deadline=$((SECONDS + 180))
    while true; do
        status=$(ssh_node ipc4 "sudo kubectl get node $node --no-headers 2>/dev/null | awk '{print \$2}'")
        if [[ "$status" == "Ready" ]]; then
            log "  $node is Ready"
            break
        fi
        if [[ $SECONDS -ge $deadline ]]; then
            die "$node did not become Ready within 3 minutes after restart — check manually"
        fi
        sleep 5
    done
    log "  pausing 30s for etcd stability before next server"
    sleep 30
done

for node in "${AGENTS[@]}"; do
    log "  restarting k3s-agent on $node"
    ssh_node "$node" "sudo systemctl restart k3s-agent"
    sleep 10
done

log "All k3s restarts done"

# ── Step 7: Clean up Flannel leftover interfaces ─────────────────────────────

log "Step 7: removing Flannel WireGuard and cni0 bridge interfaces"
# k3s does not clean these up when flannel-backend is changed. Leaving them
# creates conflicting routes for 10.42.0.0/16 that break Cilium VXLAN routing.
for node in "${SERVERS[@]}" "${AGENTS[@]}"; do
    ssh_node "$node" \
        "sudo ip link delete flannel-wg 2>/dev/null; sudo ip link delete cni0 2>/dev/null; true"
done
log "Flannel interfaces removed"

# ── Step 8: Wait for Cilium DaemonSet ───────────────────────────────────────

log "Step 8: waiting for Cilium DaemonSet to be fully Ready"
kubectl rollout restart daemonset/cilium -n cilium
kubectl rollout status daemonset/cilium -n cilium --timeout=5m
kubectl rollout status deployment/cilium-operator -n cilium --timeout=3m
log "Cilium DaemonSet ready"

# ── Step 9: Status ───────────────────────────────────────────────────────────

log "Step 9: cilium status"
kubectl exec -n cilium ds/cilium -- cilium status --brief 2>/dev/null || \
    log "  (run: kubectl exec -n cilium ds/cilium -- cilium status)"

# Run the sysctl fix again now that cilium-sysctlfix binary is installed
log "  running cilium-sysctlfix on all nodes (now that binary is present)"
for node in "${SERVERS[@]}" "${AGENTS[@]}"; do
    ssh_node "$node" \
        "sudo nsenter --mount=/proc/1/ns/mnt /var/lib/rancher/k3s/data/current/bin/cilium-sysctlfix 2>&1 || true"
done

log ""
log "═══════════════════════════════════════════════════"
log "Cilium ${CILIUM_VERSION} migration complete"
log ""
log "KNOWN LIMITATIONS (pending Pelagos fixes):"
log "  pelagos#476: pods receive reserved:init identity — pod-to-pod traffic blocked"
log "  pelagos#477: /run/cilium/bpf BPF mount is NOT persistent — re-run after any reboot"
log "  pelagos#478: L7 proxy disabled (l7Proxy=false) — only L3/L4 policy enforced"
log ""
log "When Pelagos fixes are released:"
log "  1. Run: scripts/install-pelagos.sh"
log "  2. Re-run this script (or helm upgrade removing the workaround flags)"
log "  3. Test: kubectl apply -f experiments/09-network-policies/"
log "═══════════════════════════════════════════════════"
