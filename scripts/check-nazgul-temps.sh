#!/usr/bin/env bash
# Check nazgul's CPU/NVMe/HDD temperatures via direct SSH.
# Usage: bash scripts/check-nazgul-temps.sh
#
# Nazgul isn't scraped by its own Prometheus (no node_exporter target for
# itself), so unlike the ipc4-9 nodes -- covered by cluster-health.sh via
# Prometheus -- this is the only source for its temps. Formerly part of a
# combined check-temps.sh that also SSHed to ipc4-9; that half is now
# redundant with cluster-health.sh's Prometheus-based CPU/NVMe temps (and
# doesn't work under gptel's sandboxed run_shell_k8s tool anyway, since
# ~/.ssh is denied there), so this script was trimmed to nazgul only.
set -euo pipefail

SSH="ssh -o ControlMaster=no -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o BatchMode=yes"

read -r cpu nv hdds < <($SSH root@nazgul.taildd208.ts.net \
  "sensors -u 2>/dev/null | awk '/k10temp/{k=1} k&&/temp1_input/{cpu=\$2;k=0} /^nvme/{n=1} n&&/temp1_input/{nv=\$2;n=0} /drivetemp/{d=1} d&&/temp1_input/{s+=\$2;c++;d=0} END{printf \"%.0f %.0f %.0f\n\",cpu,nv,s/c}'")

echo "nazgul:"
echo "  CPU (k10temp): ${cpu}°C"
echo "  NVMe: ${nv}°C"
echo "  HDDs (avg): ${hdds}°C"

WARN=""
[ "${cpu%.*}"  -ge 70 ] 2>/dev/null && WARN="${WARN}WARN: CPU ${cpu}°C >= 70°C\n"
[ "${nv%.*}"   -ge 70 ] 2>/dev/null && WARN="${WARN}WARN: NVMe ${nv}°C >= 70°C\n"
[ "${hdds%.*}" -ge 50 ] 2>/dev/null && WARN="${WARN}WARN: HDDs avg ${hdds}°C >= 50°C\n"

if [ -n "$WARN" ]; then
  printf "\n$WARN"
else
  echo
  echo "All temps normal."
fi
