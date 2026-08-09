#!/usr/bin/env bash
# Defers/advances tonight's or tomorrow's automated cluster startup to a
# different local time on nazgul, without permanently changing the standing
# 05:00 schedule -- OR, if the given time has already passed today, checks
# whether the cluster is already up and starts it immediately if it isn't.
#
# The standing schedule (root's crontab on nazgul, not in git) is:
#   0 21 * * *  ...pelagos run ... night-off.sh...
#   0 5  * * *  ...pelagos run ... morning-on.sh...
#
# Future HH:MM today:
#   Same mechanism as set-shutdown-time.sh: caches the crontab to
#   /etc/cluster-scheduler/crontab.default (first run only), then installs a
#   one-off crontab entry for today that runs morning-on.sh at HH:MM instead
#   of 05:00, chained with a restore of crontab.default right after. The
#   21:00 night-off line is carried over unchanged. Next morning reverts to
#   the standard 05:00 startup automatically.
#
# Past/now HH:MM today:
#   No scheduling. Reports that the time has already passed, checks node
#   power state via the Kasa strip, and if the cluster isn't already up,
#   runs morning-on.sh immediately.
set -euo pipefail

NAZGUL="root@nazgul.taildd208.ts.net"
DEFAULT_FILE="/etc/cluster-scheduler/crontab.default"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <HH:MM>  (24hr, nazgul's local time zone)" >&2
    exit 1
fi

target="$1"
if [[ ! "$target" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
    echo "error: '$target' is not a valid 24hr HH:MM time" >&2
    exit 1
fi
target_hour="${BASH_REMATCH[1]#0}"
target_min="${BASH_REMATCH[2]#0}"
[[ -z "$target_hour" ]] && target_hour=0
[[ -z "$target_min" ]] && target_min=0

# shellcheck disable=SC2087
ssh "$NAZGUL" bash -s -- "$DEFAULT_FILE" "$target_hour" "$target_min" "$target" <<'REMOTE'
set -euo pipefail
default_file="$1"
target_hour="$2"
target_min="$3"
target_hhmm="$4"

if [[ ! -f "$default_file" ]]; then
    echo "==> caching current crontab as the canonical default"
    mkdir -p "$(dirname "$default_file")"
    crontab -l > "$default_file"
fi

morning_on_line=$(grep 'morning-on.sh' "$default_file")
night_off_line=$(grep 'night-off.sh' "$default_file")
morning_on_cmd=${morning_on_line#* }
morning_on_cmd=$(echo "$morning_on_cmd" | cut -d' ' -f5-)

now_epoch=$(date +%s)
today=$(date +%Y-%m-%d)
target_epoch=$(date -d "$today $target_hhmm" +%s)

if (( target_epoch > now_epoch )); then
    day=$(date +%d)
    month=$(date +%m)
    {
        echo "# one-off override installed $(date): startup moved to $target_hhmm"
        echo "$target_min $target_hour $day $month * $morning_on_cmd; crontab $default_file"
        echo "$night_off_line"
    } > /tmp/crontab.override
    crontab /tmp/crontab.override
    rm -f /tmp/crontab.override
    echo "==> startup moved to $target_hhmm (nazgul local time: $(date +%Z))"
    echo "==> schedule reverts to the standard 05:00 startup automatically right after it runs"
    crontab -l
    exit 0
fi

echo "==> $target_hhmm has already passed today (now is $(date +%H:%M)) -- not scheduling"

echo "==> checking node power state..."
status=$(pelagos run --rm --network=bridge localhost:5004/cluster-scheduler:latest python3 /scripts/cluster-kasa-outlet.py status)
echo "$status"

if [[ "$(echo "$status" | grep -c 'ON ')" -eq 6 ]]; then
    echo "==> all 6 nodes already powered on -- cluster is already up, nothing to do"
    exit 0
fi

echo "==> cluster is not fully up -- starting it now"
eval "$morning_on_cmd"
REMOTE
