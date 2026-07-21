#!/usr/bin/env bash
# shutdown-cluster.sh (container variant)
# Gracefully drains and shuts down the entire k3s cluster.
# Designed to run from a container on nazgul: uses direct LAN IPs,
# no ProxyJump, no tailnet. kubectl hits kube-vip at 192.168.88.58.
#
# Topology: ipc4=.55, ipc5=.56, ipc6=.57 (control-plane+etcd)
#           ipc7=.63, ipc8=.64, ipc9=.65 (workers)

set -euo pipefail

export KUBECONFIG=/etc/cluster-scheduler/kubeconfig

SSH="ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
WORKERS="ipc7 ipc8 ipc9"
CONTROL_PLANE_SECONDARY="ipc5 ipc6"
CONTROL_PLANE_SEED="ipc4"
ALL_NODES="$WORKERS $CONTROL_PLANE_SECONDARY $CONTROL_PLANE_SEED"

declare -A NODE_IP=(
    [ipc4]=192.168.88.55
    [ipc5]=192.168.88.56
    [ipc6]=192.168.88.57
    [ipc7]=192.168.88.63
    [ipc8]=192.168.88.64
    [ipc9]=192.168.88.65
)

echo "==> Cordoning all nodes..."
for node in $ALL_NODES; do
    echo "    cordoning $node"
    kubectl cordon "$node"
done

echo ""
echo "==> Removing KubeVirt PodDisruptionBudgets before drain (recreated by virt-operator on restart)..."
kubectl delete pdb -n kubevirt --all --ignore-not-found 2>/dev/null || true

echo ""
echo "==> Draining worker nodes..."
for node in $WORKERS; do
    echo "    draining $node"
    kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=120s
done

echo ""
echo "==> Draining secondary control-plane nodes..."
for node in $CONTROL_PLANE_SECONDARY; do
    echo "    draining $node"
    kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s
done

echo ""
echo "==> Draining seed control-plane (ipc4)..."
kubectl drain "$CONTROL_PLANE_SEED" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s

echo ""
echo "==> Shutting down worker nodes..."
for node in $WORKERS; do
    echo "    shutting down $node (${NODE_IP[$node]})"
    $SSH "cb@${NODE_IP[$node]}" sudo shutdown -h now || true
done

echo ""
echo "==> Shutting down secondary control-plane nodes..."
for node in $CONTROL_PLANE_SECONDARY; do
    echo "    shutting down $node (${NODE_IP[$node]})"
    $SSH "cb@${NODE_IP[$node]}" sudo shutdown -h now || true
done

echo ""
echo "==> Waiting 10 seconds before shutting down seed (ipc4)..."
sleep 10

echo "==> Shutting down ipc4 (${NODE_IP[$CONTROL_PLANE_SEED]})..."
$SSH "cb@${NODE_IP[$CONTROL_PLANE_SEED]}" sudo shutdown -h now || true

echo ""
echo "==> Done. All nodes have been sent the shutdown signal."
