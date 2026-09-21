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

  # ups.realpower (measured, watts) isn't exposed by every CyberPower HID
  # data revision - nazgul's older USB HID profile only reports ups.load
  # and ups.realpower.nominal, not a live wattage reading. Fall back to
  # deriving it (load% * nominal watts) so both UPSes still get this
  # metric, but tag the source so a consumer can tell measured from derived.
  REALPOWER=$(get ups.realpower)
  REALPOWER_SOURCE="measured"
  if [ -z "$REALPOWER" ]; then
    LOAD=$(get ups.load)
    NOMINAL=$(get ups.realpower.nominal)
    if [ -n "$LOAD" ] && [ -n "$NOMINAL" ]; then
      REALPOWER=$(awk -v l="$LOAD" -v n="$NOMINAL" 'BEGIN{printf "%.1f", l/100*n}')
      REALPOWER_SOURCE="derived"
    fi
  fi
  if [ -n "$REALPOWER" ]; then
    echo '# HELP nut_ups_realpower_watts Real power draw, watts (measured directly from ups.realpower when the UPS reports it; otherwise derived from ups.load percent times ups.realpower.nominal)'
    echo '# TYPE nut_ups_realpower_watts gauge'
    echo "nut_ups_realpower_watts{ups=\"${UPS_NAME}\",source=\"${REALPOWER_SOURCE}\"} ${REALPOWER}"
  fi

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
