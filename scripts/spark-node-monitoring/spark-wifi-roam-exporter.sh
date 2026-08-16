#!/bin/bash
# Counts wlP9s9 AP-reassociation events since this script was first installed,
# exposed as a Prometheus counter. Set up 2026-08-16 to empirically check
# whether unpinning the BSSID (see orgfiles wireless-isolation.md) lets the
# MT7925 roaming storm resume, without needing anyone to babysit dmesg live --
# just check spark_wifi_roam_total's rate over time later.
set -euo pipefail
STATE=/var/lib/node-monitoring/wifi_roam_count
OUT=/var/lib/node_exporter/textfile_collector/spark_wifi_roam.prom
TMP="${OUT}.$$"

mkdir -p /var/lib/node-monitoring
[ -f "$STATE" ] || echo 0 > "$STATE"

NEW=$(journalctl -k --since "-40 seconds" 2>/dev/null | grep -c 'disconnect from AP' || true)
TOTAL=$(( $(cat "$STATE") + NEW ))
echo "$TOTAL" > "$STATE"

{
  echo '# HELP spark_wifi_roam_total Cumulative wlP9s9 AP-reassociation events since this exporter was installed'
  echo '# TYPE spark_wifi_roam_total counter'
  echo "spark_wifi_roam_total $TOTAL"
} > "$TMP"
mv "$TMP" "$OUT"
