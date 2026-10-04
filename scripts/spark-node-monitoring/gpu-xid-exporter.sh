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
  # `|| true` on each pipeline below is deliberate, not a swallowed error:
  # grep exits 1 when nothing matches, which under `pipefail` is the
  # *correct, happy-path* outcome here (zero Xid errors this boot) --
  # without this, `set -e` aborted the whole script before it ever wrote
  # the file, leaving node_exporter serving a stale reading from whatever
  # boot last had a real error. Confirmed live 2026-10-04: this exact bug
  # left the exporter failing silently for 6+ days (every 30s, since the
  # very start of the current boot), freezing the metric at a count
  # leftover from the *previous* boot -- exactly the kind of "the
  # alerting itself is broken" gap this whole exporter exists to avoid.
  journalctl -k -b 0 --no-pager -o cat 2>/dev/null \
    | grep -oE 'NVRM: Xid \(PCI:[^)]+\): [0-9]+' \
    | grep -oE '[0-9]+$' \
    | sort -n | uniq -c \
    | awk '{printf "spark_gpu_xid_errors_total{xid=\"%s\"} %s\n", $2, $1}' \
    || true

  # A monotonic since-boot count alone can't say whether a fault is
  # ongoing or a one-off from days ago -- also expose *when* each Xid was
  # last seen, so callers can compute elapsed time and judge current
  # health instead of just "has this ever happened since boot".
  echo '# HELP spark_gpu_xid_last_seen_timestamp_seconds Unix timestamp of the most recent NVIDIA Xid kernel error since boot, by Xid code'
  echo '# TYPE spark_gpu_xid_last_seen_timestamp_seconds gauge'
  journalctl -k -b 0 --no-pager -o short-iso 2>/dev/null \
    | grep -E 'NVRM: Xid \(PCI:[^)]+\): [0-9]+' \
    | while IFS= read -r line; do
        ts="${line%% *}"
        xid=$(grep -oE 'NVRM: Xid \(PCI:[^)]+\): [0-9]+' <<<"$line" | grep -oE '[0-9]+$')
        epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
        printf '%s %s\n' "$xid" "$epoch"
      done \
    | awk '{last[$1]=$2} END {for (x in last) printf "spark_gpu_xid_last_seen_timestamp_seconds{xid=\"%s\"} %s\n", x, last[x]}' \
    || true
} > "$TMP"
mv "$TMP" "$OUT"
