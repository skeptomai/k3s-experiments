#!/usr/bin/env bash
# Apply the durable node-class labels (hardware tier) to all cluster nodes, so
# workloads can be scheduled by capability via a nodeSelector/affinity on
# `node-class`:
#
#   standard    = 2-core / 4-thread Intel Pentium Gold G5400T   (ipc1, ipc2, ipc3)
#   performance = 6-core / 12-thread Intel Core i5-12500T (35W)  (ipc4, ipc5, ipc6)
#   fastest     = 6-core / 12-thread Intel Core i5-12500  (65W)  (ipc7, ipc8, ipc9)
#
# performance vs fastest: same 6c/12t Alder Lake die, but the non-T i5-12500 in
# ipc7-9 has a 65W TDP (vs the 35W i5-12500T in ipc4-6), so it holds higher
# sustained all-core clocks — the fastest tier for CPU-bound work (e.g. builds).
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
PERFORMANCE="ipc4 ipc5 ipc6"   # i5-12500T (35W), 6c/12t, 32GB
FASTEST="ipc7 ipc8 ipc9"       # i5-12500 non-T (65W), 6c/12t, 16GB

echo "=== labelling standard (2-core Pentium): $STANDARD ==="
$SSH "sudo kubectl label node $STANDARD node-class=standard --overwrite"
echo "=== labelling performance (i5-12500T, 35W): $PERFORMANCE ==="
$SSH "sudo kubectl label node $PERFORMANCE node-class=performance --overwrite"
echo "=== labelling fastest (i5-12500 non-T, 65W): $FASTEST ==="
$SSH "sudo kubectl label node $FASTEST node-class=fastest --overwrite"

echo "--- result ---"
$SSH "sudo kubectl get nodes -L node-class -L node-role.kubernetes.io/control-plane"
