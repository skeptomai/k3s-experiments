#!/bin/bash
# Writes CPU/NVMe/WiFi-radio temperatures as Prometheus textfile-collector
# metrics. node_exporter's built-in hwmon/thermal_zone collectors are
# DELIBERATELY disabled (see node_exporter.service) -- on this system they
# do hundreds of sequential sysfs reads and were blocking HTTP responses
# behind an internal lock for 15s+ (confirmed via strace, 2026-08-16).
# This script does the same sensor reads on its own schedule, decoupled
# from the live scrape path entirely.
set -euo pipefail
OUT=/var/lib/node_exporter/textfile_collector/spark_thermal.prom
TMP="${OUT}.$$"

{
  echo '# HELP spark_thermal_celsius Sensor temperature via lm-sensors (chip/sensor labeled)'
  echo '# TYPE spark_thermal_celsius gauge'
  sensors -u 2>/dev/null | awk '
    /^[a-zA-Z0-9_-]+-[a-zA-Z0-9_-]+$/ { chip = $0; next }
    /^[A-Za-z0-9 ]+:$/ { sensor = $0; sub(/:$/, "", sensor); next }
    /_input:/ {
      val = $2
      gsub(/[^0-9.\-]/, "", val)
      gsub(/"/, "\\\"", chip)
      gsub(/"/, "\\\"", sensor)
      gsub(/ /, "_", sensor)
      printf "spark_thermal_celsius{chip=\"%s\",sensor=\"%s\"} %s\n", chip, sensor, val
    }
  '
} > "$TMP"
mv "$TMP" "$OUT"
