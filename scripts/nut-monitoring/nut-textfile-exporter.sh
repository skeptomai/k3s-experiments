#!/bin/bash
# Writes UPS metrics (via NUT's upsc, querying this host's own local upsd)
# as Prometheus textfile-collector metrics. Same script deployed on both
# ipc4 and nazgul, unmodified - each has its own local CyberPower LX1500GU3
# and its own upsd, both named "cyberpower" in NUT config. Same
# atomic-write-then-mv pattern as spark-thermal-exporter.sh.
set -euo pipefail
UPS_NAME="${UPS_NAME:-cyberpower}"
OUT="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}/nut_ups.prom"
TMP="${OUT}.$$"

DATA=$(upsc "${UPS_NAME}@localhost" 2>/dev/null) || {
  # upsd unreachable (e.g. mid-restart) - emit nothing rather than a stale
  # or malformed file; node_exporter's textfile collector treats a missing
  # file as "no metrics from this collector", not an error, so a query
  # just sees a gap instead of wrong data.
  rm -f "$OUT"
  exit 0
}

get() { echo "$DATA" | awk -F': ' -v k="$1" '$1==k{print $2; exit}'; }

STATUS=$(get ups.status)
is_flag() { case " $STATUS " in *" $1 "*) echo 1 ;; *) echo 0 ;; esac; }

{
  echo '# HELP nut_ups_battery_charge_percent Battery charge, percent'
  echo '# TYPE nut_ups_battery_charge_percent gauge'
  echo "nut_ups_battery_charge_percent{ups=\"${UPS_NAME}\"} $(get battery.charge)"

  echo '# HELP nut_ups_battery_runtime_seconds Estimated runtime remaining on battery, seconds'
  echo '# TYPE nut_ups_battery_runtime_seconds gauge'
  echo "nut_ups_battery_runtime_seconds{ups=\"${UPS_NAME}\"} $(get battery.runtime)"

  echo '# HELP nut_ups_load_percent UPS load, percent of rated capacity'
  echo '# TYPE nut_ups_load_percent gauge'
  echo "nut_ups_load_percent{ups=\"${UPS_NAME}\"} $(get ups.load)"

  echo '# HELP nut_ups_input_voltage_volts Input (mains) voltage'
  echo '# TYPE nut_ups_input_voltage_volts gauge'
  echo "nut_ups_input_voltage_volts{ups=\"${UPS_NAME}\"} $(get input.voltage)"

  echo '# HELP nut_ups_battery_voltage_volts Battery voltage'
  echo '# TYPE nut_ups_battery_voltage_volts gauge'
  echo "nut_ups_battery_voltage_volts{ups=\"${UPS_NAME}\"} $(get battery.voltage)"

  # ups.status is a space-separated flag string (e.g. "OL", "OB LB") - one
  # boolean gauge per flag that actually matters operationally, rather than
  # trying to expose the raw string (Prometheus gauges aren't strings).
  echo '# HELP nut_ups_status_online Mains power present and UPS online (1=yes)'
  echo '# TYPE nut_ups_status_online gauge'
  echo "nut_ups_status_online{ups=\"${UPS_NAME}\"} $(is_flag OL)"

  echo '# HELP nut_ups_status_on_battery Running on battery, mains lost (1=yes)'
  echo '# TYPE nut_ups_status_on_battery gauge'
  echo "nut_ups_status_on_battery{ups=\"${UPS_NAME}\"} $(is_flag OB)"

  echo '# HELP nut_ups_status_low_battery Battery critically low (1=yes)'
  echo '# TYPE nut_ups_status_low_battery gauge'
  echo "nut_ups_status_low_battery{ups=\"${UPS_NAME}\"} $(is_flag LB)"
} > "$TMP"
mv "$TMP" "$OUT"
