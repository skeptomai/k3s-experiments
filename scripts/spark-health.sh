#!/usr/bin/env bash
# Spark (spark-0d93, the DGX host running vLLM/Nemotron) health check.
#
# Spark is NOT a k3s node -- it's a standalone GPU host reachable only via
# Prometheus scrape metrics (job="spark_node_exporter") from omen/gptel's
# run_shell_k8s sandbox, which allow-lists nazgul.taildd208.ts.net:9090 but
# not Spark's own tailnet address (see ~/.config/gptel/srt-settings-k8s.json).
# Deliberately does NOT touch kubectl/node/pod state -- added after gptel's
# k8s preset answered "check spark" by misreporting the unrelated AWS
# Graviton build node (scripts/aws-build-node.sh, a genuine k3s node) as
# "the Spark node", because cluster-health.sh's combined node-list-plus-temps
# output put them next to each other. This script only ever reports on
# spark-0d93 itself, via metrics job="spark_node_exporter" -- kept in sync
# with scripts/spark-node-monitoring/README.md if metric names change there.
set -euo pipefail

PROM="http://nazgul.taildd208.ts.net:9090"
JOB="spark_node_exporter"

q() {
  curl -s -G "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // empty'
}

up=$(q "up{job=\"$JOB\"}")

if [ "$up" != "1" ]; then
  echo "Spark (spark-0d93): node_exporter scrape is DOWN or unreachable from Prometheus."
  echo "This means the host, its network, or node_exporter itself may be down -- not necessarily vLLM specifically, and not related to any k3s node status."
  exit 1
fi

echo "Spark (spark-0d93): node_exporter reachable (up)."

uptime_h=$(q "(time() - node_boot_time_seconds{job=\"$JOB\"})/3600")
[ -n "$uptime_h" ] && printf "Host uptime: %.1f hours\n" "$uptime_h"

echo
echo "Temperatures:"
cpu_temp=$(q 'spark_thermal_celsius{chip="acpitz-acpi-0"}')
[ -n "$cpu_temp" ] && printf "  CPU: %.0f°C\n" "$cpu_temp"

gpu_temp=$(q 'spark_gpu_temperature_celsius')
[ -n "$gpu_temp" ] && printf "  GPU: %.0f°C\n" "$gpu_temp"

nvme_temp=$(q 'spark_thermal_celsius{chip="nvme-pci-40100",sensor="Composite"}')
[ -n "$nvme_temp" ] && printf "  NVMe: %.0f°C\n" "$nvme_temp"

echo
echo "GPU Xid faults (a nonzero count just means one happened at some point since boot; elapsed time since the last occurrence is the better \"is it healthy right now\" signal -- see docs/spark-vllm-xid13-postmortem.md for the known 2026-08-28 Xid 13 incident):"
counts=$(curl -s -G "$PROM/api/v1/query" --data-urlencode 'query=spark_gpu_xid_errors_total' \
  | jq -r '.data.result[] | .metric.xid + " " + .value[1]')
if [ -n "$counts" ]; then
  elapsed=$(curl -s -G "$PROM/api/v1/query" \
    --data-urlencode 'query=(time() - spark_gpu_xid_last_seen_timestamp_seconds)/3600' \
    | jq -r '.data.result[] | .metric.xid + " " + .value[1]')
  join -j1 <(echo "$counts" | sort) <(echo "$elapsed" | sort) \
    | awk '{printf "  Xid %s: %s occurrence(s) since boot, last seen %.1f hours ago\n", $1, $2, $3}'
else
  echo "  None."
fi
