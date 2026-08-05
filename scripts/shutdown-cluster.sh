#!/usr/bin/env bash
# shutdown-cluster.sh
# Gracefully drains and shuts down the entire k3s cluster.
# Run from omen. Cordons all nodes, drains workers, drains control plane,
# then shuts down workers first and ipc4 last.
#
# Topology: ipc4/5/6 = control-plane+etcd (ipc4 is seed/jump host)
#           ipc7/8/9 = workers

set -euo pipefail

SSH="ssh -i $HOME/.ssh/id_rsa -o StrictHostKeyChecking=accept-new"
WORKERS="ipc7 ipc8 ipc9"
CONTROL_PLANE_SECONDARY="ipc5 ipc6"
CONTROL_PLANE_SEED="ipc4"
ALL_NODES="$WORKERS $CONTROL_PLANE_SECONDARY $CONTROL_PLANE_SEED"

echo "==> Cordoning all nodes..."
for node in $ALL_NODES; do
  echo "    cordoning $node"
  kubectl cordon "$node"
done

# virt-operator recreates virt-api-pdb / virt-controller-pdb on its own
# reconcile loop, so a single delete before the first drain isn't enough --
# it's back within the couple minutes it takes to reach later drain phases.
# With every node cordoned, a 2-replica component's "other" pod also has
# nowhere to reschedule to, so it sits Pending while the recreated PDB
# blocks the last replica's eviction indefinitely. Delete immediately
# before EVERY drain phase, not just once at the start.
drop_kubevirt_pdbs() {
  kubectl delete pdb -n kubevirt --all --ignore-not-found 2>/dev/null || true
}

echo ""
echo "==> Removing KubeVirt PodDisruptionBudgets before drain (recreated by virt-operator on restart)..."
drop_kubevirt_pdbs

echo ""
echo "==> Draining worker nodes (ignore daemonsets, delete emptydir)..."
for node in $WORKERS; do
  echo "    draining $node"
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=120s
done

drop_kubevirt_pdbs
echo ""
echo "==> Draining secondary control-plane nodes..."
for node in $CONTROL_PLANE_SECONDARY; do
  echo "    draining $node"
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s
done

drop_kubevirt_pdbs
echo ""
echo "==> Draining seed control-plane (ipc4)..."
kubectl drain "$CONTROL_PLANE_SEED" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s

echo ""
echo "==> Shutting down worker nodes..."
for node in $WORKERS; do
  echo "    shutting down $node"
  $SSH -J "cb@ipc4.taildd208.ts.net" "cb@$node" sudo shutdown -h now || true
done

echo ""
echo "==> Shutting down secondary control-plane nodes..."
for node in $CONTROL_PLANE_SECONDARY; do
  echo "    shutting down $node"
  $SSH -J "cb@ipc4.taildd208.ts.net" "cb@$node" sudo shutdown -h now || true
done

echo ""
echo "==> Waiting 10 seconds before shutting down seed (ipc4)..."
sleep 10

echo "==> Shutting down ipc4 (seed control-plane)..."
$SSH "cb@ipc4.taildd208.ts.net" sudo shutdown -h now || true

echo ""
echo "==> Done. All nodes have been sent the shutdown signal."
