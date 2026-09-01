#!/usr/bin/env bash
# Node/pod/DaemonSet/Kustomization readiness plus CPU/NVMe/GPU temperatures --
# external-facing equivalent of manifests/open-webui/tools/cluster_health.py
# (which only covers node/pod status + CPU/GPU temps) for use from omen (via
# gptel's run_shell_k8s tool, or interactively). Authenticates via
# ~/.kube/config + kubectl instead of the in-cluster ServiceAccount token
# that only resolves from inside a pod (https://kubernetes.default.svc isn't
# reachable from omen). Keep the node/pod checks and the shared Prometheus
# queries in sync with cluster_health.py if either one changes.
#
# A fast, passive summary -- not a replacement for
# dotfiles/scripts/check-cluster-health.sh (`/check-cluster-health` skill),
# which does deeper *active* probes (live NetworkPolicy enforcement test,
# OpenBao seal state, KubeVirt phase, app HTTP health) that need SSH+sudo
# kubectl on ipc4 and can't be expressed as Prometheus queries.
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
# Pod phase alone can't see this -- a crash-looping container leaves the
# pod's phase at "Running" (only containerStatuses reflects it), so the
# problem_pods check above misses it entirely. kube-state-metrics exposes
# it directly as a Prometheus gauge instead of needing the containerStatuses
# jq/python dig the old check-cluster-health.sh (now retired -- see
# dotfiles/scripts/check-cluster-health.sh for the actively-maintained,
# deeper cousin of this script that still needs SSH+sudo kubectl on ipc4)
# used to do.
clbo=$(curl -s -G "$PROM/api/v1/query" \
  --data-urlencode 'query=kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} == 1' \
  | jq -r '.data.result[] | "  " + .metric.namespace + "/" + .metric.pod + "  container=" + .metric.container')
if [ -n "$clbo" ]; then
  echo "CrashLoopBackOff pods:"
  echo "$clbo"
else
  echo "CrashLoopBackOff pods: none."
fi

echo
# All DaemonSets, not just MetalLB/SPIRE -- a generic ready-vs-desired join
# catches Cilium, kube-vip, virt-handler etc. too, not just the two the old
# script happened to name.
ready_ds=$(curl -s -G "$PROM/api/v1/query" --data-urlencode 'query=kube_daemonset_status_number_ready' \
  | jq -r '.data.result[] | .metric.namespace + "/" + .metric.daemonset + " " + .value[1]')
desired_ds=$(curl -s -G "$PROM/api/v1/query" --data-urlencode 'query=kube_daemonset_status_desired_number_scheduled' \
  | jq -r '.data.result[] | .metric.namespace + "/" + .metric.daemonset + " " + .value[1]')
not_ready_ds=$(join -j1 <(echo "$ready_ds" | sort) <(echo "$desired_ds" | sort) \
  | awk '$2 != $3 || $3+0 == 0 {printf "  %s: %s/%s Ready\n", $1, $2, $3}')
if [ -n "$not_ready_ds" ]; then
  echo "DaemonSets NOT fully Ready:"
  echo "$not_ready_ds"
else
  echo "DaemonSets: all Ready."
fi

echo
not_ready_ks=$(kubectl get kustomization -A --no-headers 2>/dev/null | awk '$4 != "True" {print "  " $1 "/" $2 ": " $4}')
if [ -n "$not_ready_ks" ]; then
  echo "Flux Kustomizations NOT Ready:"
  echo "$not_ready_ks"
else
  echo "Flux Kustomizations: all Ready."
fi

echo
echo "CPU package temps:"
curl -s -G "$PROM/api/v1/query" \
  --data-urlencode 'query=node_hwmon_temp_celsius{chip="platform_coretemp_0",sensor="temp1"}' \
  | jq -r '.data.result[] | "  " + .metric.node + ": " + (.value[1] | tonumber | round | tostring) + "°C"' \
  | sort

echo
echo "NVMe temps:"
curl -s -G "$PROM/api/v1/query" \
  --data-urlencode 'query=node_hwmon_temp_celsius{chip="nvme_nvme0",sensor="temp1"}' \
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
