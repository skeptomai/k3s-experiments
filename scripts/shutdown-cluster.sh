#!/usr/bin/env bash
# shutdown-cluster.sh
# Gracefully drains and shuts down the entire k3s cluster.
# Run from omen. Cordons all nodes, drains workers, drains control plane,
# then shuts down workers first and ipc1 last.

set -euo pipefail

SSH="ssh -i $HOME/.ssh/Omen"
WORKERS="ipc2 ipc3 ipc4 ipc5 ipc6"
CONTROL_PLANE="ipc1"

echo "==> Cordoning all nodes..."
for node in $CONTROL_PLANE $WORKERS; do
  echo "    cordoning $node"
  kubectl cordon "$node"
done

echo ""
echo "==> Draining worker nodes (ignore daemonsets, delete emptydir)..."
for node in $WORKERS; do
  echo "    draining $node"
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=120s
done

echo ""
echo "==> Draining control plane (ipc1)..."
kubectl drain "$CONTROL_PLANE" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s

echo ""
echo "==> Shutting down worker nodes..."
for node in $WORKERS; do
  echo "    shutting down $node"
  $SSH -J cb@ipc1.taildd208.ts.net "cb@$node" sudo shutdown -h now || true
done

echo ""
echo "==> Waiting 10 seconds before shutting down control plane..."
sleep 10

echo "==> Shutting down ipc1 (control plane)..."
$SSH cb@ipc1.taildd208.ts.net sudo shutdown -h now || true

echo ""
echo "==> Done. All nodes have been sent the shutdown signal."
