#!/bin/bash
# Writes GPU temperature as a Prometheus textfile-collector metric.
# node_exporter has no native NVIDIA support; this bridges nvidia-smi -> the
# textfile collector directory node_exporter already watches.
set -euo pipefail
OUT=/var/lib/node_exporter/textfile_collector/gpu_temp.prom
TMP="${OUT}.$$"
TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits)
{
  echo '# HELP spark_gpu_temperature_celsius Current GPU temperature (nvidia-smi temperature.gpu)'
  echo '# TYPE spark_gpu_temperature_celsius gauge'
  echo "spark_gpu_temperature_celsius ${TEMP}"
} > "$TMP"
mv "$TMP" "$OUT"
