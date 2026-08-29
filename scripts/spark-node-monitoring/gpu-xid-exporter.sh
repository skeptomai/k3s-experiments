#!/bin/bash
# Writes NVIDIA Xid error counts (from the current boot's kernel ring
# buffer) as a Prometheus textfile-collector counter, labeled by Xid code.
# Xid errors indicate a GPU driver-level fault -- anything from a
# recoverable graphics-engine exception up to the GPU falling off the bus
# entirely. See k3s-experiments docs/spark-vllm-xid13-postmortem.md for the
# 2026-08-28 incident that motivated this: a burst of Xid 13 crashed
# vLLM's engine with zero alerting to catch it.
#
# Scoped to the current boot (`journalctl -k -b 0`) so the counter resets
# naturally on reboot, matching normal Prometheus counter semantics --
# increase() handles a reset-to-lower-value correctly as a discontinuity,
# so this needs no extra bookkeeping to avoid re-alerting on old history
# from a previous boot.
set -euo pipefail
OUT=/var/lib/node_exporter/textfile_collector/gpu_xid.prom
TMP="${OUT}.$$"

{
  echo '# HELP spark_gpu_xid_errors_total Count of NVIDIA Xid kernel errors since boot, by Xid code'
  echo '# TYPE spark_gpu_xid_errors_total counter'
  journalctl -k -b 0 --no-pager -o cat 2>/dev/null \
    | grep -oE 'NVRM: Xid \(PCI:[^)]+\): [0-9]+' \
    | grep -oE '[0-9]+$' \
    | sort -n | uniq -c \
    | awk '{printf "spark_gpu_xid_errors_total{xid=\"%s\"} %s\n", $2, $1}'
} > "$TMP"
mv "$TMP" "$OUT"
