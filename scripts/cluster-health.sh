#!/usr/bin/env bash
# Node readiness, problem pods, and CPU/GPU temperatures -- external-facing
# equivalent of manifests/open-webui/tools/cluster_health.py for use from
# omen (via gptel's run_shell_k8s tool, or interactively). Same checks, same
# Prometheus metrics, but authenticates via ~/.kube/config + kubectl instead
# of the in-cluster ServiceAccount token that only resolves from inside a
# pod (https://kubernetes.default.svc isn't reachable from omen). Keep the
# node/pod checks and the two Prometheus queries in sync with
# cluster_health.py if either one changes.
#
# Uses nazgul's tailnet hostname, not its bare LAN IP (192.168.89.2) --
# confirmed the hard way: omen isn't always on nazgul's home LAN subnet
# (192.168.89.0/24), e.g. when on a different network entirely, so the LAN
# IP alone times out with no route. nazgul.taildd208.ts.net works from
# anywhere the tailnet is up, same as how ipc4-9 are already reached.
set -euo pipefail

PROM="http://nazgul.taildd208.ts.net:9090"

echo "Nodes:"
kubectl get nodes -o json | jq -r '
  .items[] | "  " + .metadata.name + ": " +
    (if ([.status.conditions[] | select(.type=="Ready") | .status] | first) == "True"
     then "Ready" else "NotReady" end)'

echo
problem_pods=$(kubectl get pods -A -o json | jq -r '
  .items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") |
  "  " + .metadata.namespace + "/" + .metadata.name + ": " + .status.phase')
if [ -n "$problem_pods" ]; then
  echo "Pods not Running/Succeeded:"
  echo "$problem_pods"
else
  echo "Pods: all Running or Succeeded."
fi

echo
echo "CPU package temps:"
curl -s -G "$PROM/api/v1/query" \
  --data-urlencode 'query=node_hwmon_temp_celsius{chip="platform_coretemp_0",sensor="temp1"}' \
  | jq -r '.data.result[] | "  " + .metric.node + ": " + (.value[1] | tonumber | round | tostring) + "°C"' \
  | sort

echo
echo "Spark (spark-0d93) temps:"
# Spark's hwmon collector is disabled (see scripts/spark-node-monitoring/README.md
# -- it blocked HTTP responses for 15s+ on this hardware), so its CPU/NVMe
# temps come from a different metric (spark_thermal_celsius, textfile-collector
# based) than the ipc nodes' CPU temps above -- not the same query with a
# different label, genuinely a different metric name.
cpu_temp=$(curl -s -G "$PROM/api/v1/query" \
  --data-urlencode 'query=spark_thermal_celsius{chip="acpitz-acpi-0"}' \
  | jq -r '.data.result[0].value[1] // empty')
[ -n "$cpu_temp" ] && echo "  CPU: $(printf '%.0f' "$cpu_temp")°C"

gpu_temp=$(curl -s -G "$PROM/api/v1/query" --data-urlencode 'query=spark_gpu_temperature_celsius' \
  | jq -r '.data.result[0].value[1] // empty')
[ -n "$gpu_temp" ] && echo "  GPU: $(printf '%.0f' "$gpu_temp")°C"

nvme_temp=$(curl -s -G "$PROM/api/v1/query" \
  --data-urlencode 'query=spark_thermal_celsius{chip="nvme-pci-40100",sensor="Composite"}' \
  | jq -r '.data.result[0].value[1] // empty')
[ -n "$nvme_temp" ] && echo "  NVMe: $(printf '%.0f' "$nvme_temp")°C"
