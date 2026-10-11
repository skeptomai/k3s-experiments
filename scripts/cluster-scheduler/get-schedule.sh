#!/usr/bin/env bash
# Reports the effective shutdown/startup times for today -- standard
# (21:00/05:00 Europe/London) or a one-off override installed by
# set-shutdown-time.sh / set-startup-time.sh.
#
# 2026-10-11: rewritten against scheduler-tick.sh's model. nazgul's
# crontab no longer carries any scheduling information to read (just
# `* * * * * scheduler-tick.sh`) -- the real schedule lives in that
# script's hardcoded windows plus any today-dated override file under
# /etc/cluster-scheduler/.
set -euo pipefail

NAZGUL="root@nazgul.taildd208.ts.net"

ssh -o BatchMode=yes -o ConnectTimeout=10 "$NAZGUL" bash -s <<'REMOTE'
set -euo pipefail
today=$(TZ=Europe/London date +%Y-%m-%d)

describe() {
    local label="$1" default_hhmm="$2" override_file="/etc/cluster-scheduler/$3"
    if [[ -f "$override_file" ]]; then
        local ov_date ov_hhmm
        read -r ov_date ov_hhmm < "$override_file"
        if [[ "$ov_date" == "$today" ]]; then
            echo "$label: $ov_hhmm Europe/London (one-off override for today, reverts to standard $default_hhmm tomorrow)"
            return
        fi
    fi
    echo "$label: $default_hhmm Europe/London (standard)"
}

describe "Shutdown" "21:00" ".override-night-off"
describe "Startup" "05:00" ".override-morning-on"
REMOTE
