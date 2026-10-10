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
    # Same reasoning as the drains below: cordon failing here (e.g. a
    # transient API-server hiccup) must not block reaching the actual
    # SSH-based `shutdown -h now` calls at the bottom of this script --
    # those don't depend on the k8s API at all, so even a fully broken
    # kubectl phase shouldn't be the reason physical power-off never
    # happens.
    kubectl cordon "$node" || echo "    WARNING: cordon of $node failed -- continuing anyway"
done

# History of this section (kept because the failure mode is subtle and
# worth understanding before touching this again):
#
# Originally `kubectl drain` here respected PodDisruptionBudgets (the
# default), which meant virt-operator's own reconcile loop recreating
# virt-api-pdb/virt-controller-pdb mid-drain could make an eviction request
# race against the PDB's minAvailable and get rejected ("Cannot evict pod
# as it would violate the pod's disruption budget"), retried until the
# drain's own --timeout, then failed outright. A 2026-08-07 fix
# (drop_kubevirt_pdbs, deleting those PDBs immediately before EVERY node's
# drain rather than once per batch) narrowed the race window but didn't
# close it -- it recurred on 2026-10-09/10 for ipc4 specifically, and
# because no drain call here had `|| true`, `set -e` killed the whole
# script immediately, before ANY node (not just ipc4) got `shutdown -h
# now` -- the entire cluster stayed powered on all night, undetected until
# the next morning-on cron uncordoned everything ~8h later.
#
# Fixed 2026-10-10, properly this time: `--disable-eviction` makes drain
# use plain DELETE instead of the PDB-respecting Eviction API, which is the
# semantically correct choice here anyway -- a PDB protects *other*
# replicas' availability during a *partial* disruption (a rolling restart,
# one node draining while the rest of the cluster keeps serving); it's
# meaningless when literally every node is going dark together in the same
# operation. There's no "shift load to a surviving replica" when nothing
# survives. drop_kubevirt_pdbs() is gone -- bypassing eviction checking
# makes deleting the PDB pointless, it was never the pods we needed gone,
# it was the *disruption budget enforcement* we needed gone, and
# --disable-eviction does that directly instead of racing to delete the
# object enforcing it.
#
# Second, independent layer: every drain call below now tolerates its own
# failure (`|| drain_warn ...`) instead of aborting the script via `set -e`.
# --disable-eviction should make an actual failure here rare, but "rare"
# isn't "impossible" (a node going unreachable mid-drain, a kubectl API
# hiccup), and per 2026-10-10 direction: a single node's drain misbehaving
# must never be the reason the *entire cluster* stays powered on overnight.
# Losing a clean eviction for one stubborn pod on one node is an acceptable
# cost; losing the whole night's power saving to it is not. Warnings are
# still logged (not silently swallowed) so a degraded drain stays visible
# in /var/log/cluster-scheduler.log even though it no longer blocks anything.
DRAIN_WARNINGS=0
drain_warn() {
    DRAIN_WARNINGS=$((DRAIN_WARNINGS + 1))
    echo "    WARNING: drain of $1 did not complete cleanly within its timeout -- continuing anyway, $1 will still be sent shutdown -h now"
}

echo ""
echo "==> Draining worker nodes..."
for node in $WORKERS; do
    echo "    draining $node"
    kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --disable-eviction --timeout=120s \
        || drain_warn "$node"
done

echo ""
echo "==> Draining secondary control-plane nodes..."
for node in $CONTROL_PLANE_SECONDARY; do
    echo "    draining $node"
    kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --disable-eviction --timeout=120s \
        || drain_warn "$node"
done

echo ""
echo "==> Draining seed control-plane (ipc4)..."
kubectl drain "$CONTROL_PLANE_SEED" --ignore-daemonsets --delete-emptydir-data --force --disable-eviction --timeout=120s \
    || drain_warn "$CONTROL_PLANE_SEED"

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
if [[ "$DRAIN_WARNINGS" -gt 0 ]]; then
    echo "==> Done. All nodes have been sent the shutdown signal ($DRAIN_WARNINGS node(s) had a degraded/incomplete drain -- see WARNING lines above)."
else
    echo "==> Done. All nodes have been sent the shutdown signal."
fi
