#!/usr/bin/env bash
# Defers/advances tonight's or tomorrow's automated cluster startup to a
# different Europe/London time, without permanently changing the standing
# 05:00 schedule -- OR, if the given time has already passed today, checks
# whether the cluster is already up and starts it immediately if it isn't.
#
# 2026-10-11: rewritten against scheduler-tick.sh's model -- see
# set-shutdown-time.sh's header for why (nazgul's crontab carries no
# scheduling information any more, so the old "install a one-off numbered
# crontab entry" mechanism had nothing to attach to).
#
# Future HH:MM today:
#   Writes "$TODAY $HH:MM" to /etc/cluster-scheduler/.override-morning-on
#   on nazgul. scheduler-tick.sh checks that file every minute and uses it
#   instead of the standard 05:00 window for as long as its date matches
#   today. Reverts automatically tomorrow -- no explicit restore step.
#
# Past/now HH:MM today:
#   No override written. Checks node power state via the Kasa strip, and
#   if the cluster isn't already up, runs morning-on.sh immediately.
set -euo pipefail

NAZGUL="root@nazgul.taildd208.ts.net"
OVERRIDE_FILE="/etc/cluster-scheduler/.override-morning-on"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <HH:MM>  (24hr, Europe/London)" >&2
    exit 1
fi

target="$1"
if [[ ! "$target" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
    echo "error: '$target' is not a valid 24hr HH:MM time" >&2
    exit 1
fi

# shellcheck disable=SC2087
ssh "$NAZGUL" bash -s -- "$OVERRIDE_FILE" "$target" <<'REMOTE'
set -euo pipefail
override_file="$1"
target_hhmm="$2"

today=$(TZ=Europe/London date +%Y-%m-%d)
now_hm=$((10#$(TZ=Europe/London date +%H%M)))
target_hm=$((10#$(echo "$target_hhmm" | tr -d ':')))

if (( target_hm > now_hm )); then
    mkdir -p "$(dirname "$override_file")"
    echo "$today $target_hhmm" > "$override_file"
    echo "==> startup moved to $target_hhmm Europe/London"
    echo "==> reverts to the standard 05:00 startup automatically tomorrow (override is dated to today only)"
    exit 0
fi

echo "==> $target_hhmm has already passed today (now is $(TZ=Europe/London date +%H:%M) Europe/London) -- not scheduling"

echo "==> checking node power state..."
status=$(pelagos run --rm --network=bridge localhost:5004/cluster-scheduler:latest python3 /scripts/cluster-kasa-outlet.py status)
echo "$status"

if [[ "$(echo "$status" | grep -c 'ON ')" -eq 6 ]]; then
    echo "==> all 6 nodes already powered on -- cluster is already up, nothing to do"
    exit 0
fi

echo "==> cluster is not fully up -- starting it now"
pelagos run --rm --network=bridge --env TZ=Europe/London \
    --bind-ro /root/.ssh/id_rsa:/root/.ssh/id_rsa \
    --bind-ro /etc/cluster-scheduler/kubeconfig:/etc/cluster-scheduler/kubeconfig \
    --env-file /etc/cluster-scheduler/pushover.env \
    localhost:5004/cluster-scheduler:latest /scripts/morning-on.sh
REMOTE
