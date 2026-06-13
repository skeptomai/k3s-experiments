#!/usr/bin/env bash
# Apply the durable node-class labels (hardware tier) to all cluster nodes, so
# workloads can be scheduled by capability via a nodeSelector/affinity on
# `node-class`:
#
#   standard    = 2-core / 4-thread Intel Pentium Gold G5400T  (ipc1, ipc2, ipc3)
#   performance = 6-core / 12-thread Intel Core i5-12500T       (ipc4, ipc5, ipc6)
#
# Node labels are live cluster state: they survive reboots but NOT a PXE reinstall
# (a fresh node registers unlabelled). Run this after reinstalling a node — it's
# idempotent (--overwrite), so re-running is always safe.
#
# Note: ipc1 also carries the control-plane taint, so it won't actually schedule
# workloads regardless of its label; it's labelled by hardware for completeness.
set -euo pipefail

IPC1="${IPC1:-cb@ipc1.taildd208.ts.net}"
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 $IPC1"

STANDARD="ipc1 ipc2 ipc3"      # Pentium Gold G5400T, 2c/4t
PERFORMANCE="ipc4 ipc5 ipc6"   # Core i5-12500T, 6c/12t

echo "=== labelling standard (2-core Pentium): $STANDARD ==="
$SSH "sudo kubectl label node $STANDARD node-class=standard --overwrite"
echo "=== labelling performance (6-core i5): $PERFORMANCE ==="
$SSH "sudo kubectl label node $PERFORMANCE node-class=performance --overwrite"

echo "--- result ---"
$SSH "sudo kubectl get nodes -L node-class -L node-role.kubernetes.io/control-plane"
