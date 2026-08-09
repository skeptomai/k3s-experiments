#!/usr/bin/env bash
# Reports the effective shutdown/startup times currently configured in root's
# crontab on nazgul -- standard (21:00/05:00) or a one-off override installed
# by set-shutdown-time.sh / set-startup-time.sh.
set -euo pipefail

NAZGUL="root@nazgul.taildd208.ts.net"

crontab_out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$NAZGUL" crontab -l)

describe() {
    local label="$1" pattern="$2"
    local line
    line=$(echo "$crontab_out" | grep "$pattern" || true)
    if [[ -z "$line" ]]; then
        echo "$label: not scheduled"
        return
    fi
    local min hour dom mon dow
    read -r min hour dom mon dow _ <<< "$line"
    if [[ "$dom" == "*" && "$mon" == "*" ]]; then
        printf "%s: %02d:%02d (standard)\n" "$label" "$hour" "$min"
    else
        printf "%s: %02d:%02d (one-off override for %s-%s, reverts to standard after)\n" \
            "$label" "$hour" "$min" "$mon" "$dom"
    fi
}

describe "Shutdown" "night-off.sh"
describe "Startup" "morning-on.sh"
