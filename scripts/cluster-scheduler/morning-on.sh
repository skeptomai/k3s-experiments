#!/usr/bin/env bash
# Morning 5am: power on all cluster nodes, wait for Ready, then uncordon.
# Alerts resume at 05:30 automatically (silence set at 9pm expires then).
set -euo pipefail

export KUBECONFIG=/etc/cluster-scheduler/kubeconfig

ALL_NODES="ipc4 ipc5 ipc6 ipc7 ipc8 ipc9"

echo "==> [$(date)] cluster morning-on starting"
echo "==> Powering on all cluster nodes..."
python3 /scripts/cluster-kasa-outlet.py on all

echo "==> [$(date)] Waiting for API server to become reachable..."
until kubectl get nodes --request-timeout=5s >/dev/null 2>&1; do
    echo "    API server not ready yet, retrying in 15s..."
    sleep 15
done
echo "    API server is up."

echo ""
echo "==> Waiting for all 6 nodes to be Ready..."
until [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -eq 6 ]; do
    READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
    echo "    $READY/6 nodes Ready, retrying in 15s..."
    sleep 15
done
echo "    All 6 nodes Ready."

echo ""
echo "==> Restarting pelagos-cri on all nodes to clear stale overlay state from power cut..."
SSH="ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
declare -A NODE_IP=(
    [ipc4]=192.168.88.55 [ipc5]=192.168.88.56 [ipc6]=192.168.88.57
    [ipc7]=192.168.88.63 [ipc8]=192.168.88.64 [ipc9]=192.168.88.65
)
for node in $ALL_NODES; do
    echo "    restarting pelagos-cri on $node"
    $SSH "cb@${NODE_IP[$node]}" sudo systemctl restart pelagos-cri \
        || echo "    WARNING: failed to restart pelagos-cri on $node"
done
echo "    Waiting 10s for CRI to settle..."
sleep 10

echo ""
echo "==> Uncordoning all nodes..."
for node in $ALL_NODES; do
    echo "    uncordoning $node"
    kubectl uncordon "$node"
done

echo ""
echo "==> Recycling SPIRE agent pods to force fresh bootstrap bundle fetch..."
# SPIRE CA rotates every ~12h. Agent pod objects persist across power cycles and the
# init container (which fetches the trust bundle) only runs once per pod creation.
# After one or more CA rotations, the stale bootstrap bundle causes TLS handshake
# failure on reconnect. Deleting pods here is cheap: init container takes <30s.
kubectl delete pods -n spire -l app=spire-agent --ignore-not-found
echo "    Waiting 45s for SPIRE agents to re-attest..."
sleep 45
SPIRE_READY=$(kubectl get pods -n spire -l app=spire-agent --no-headers 2>/dev/null | grep -c "1/1" || true)
echo "    $SPIRE_READY/6 SPIRE agents Ready"

echo ""
echo "==> [$(date)] Done. Cluster is up and scheduling. Alerts resume at 05:30."
