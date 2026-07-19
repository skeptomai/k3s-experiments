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
echo "==> Uncordoning all nodes..."
for node in $ALL_NODES; do
    echo "    uncordoning $node"
    kubectl uncordon "$node"
done

echo ""
echo "==> [$(date)] Done. Cluster is up and scheduling. Alerts resume at 05:30."
