#!/usr/bin/env bash
# Defers tonight's automated cluster shutdown to a different local time on nazgul,
# without permanently changing the standing 21:00 schedule.
#
# The standing schedule (root's crontab on nazgul, not in git) is:
#   0 21 * * *  ...pelagos run ... night-off.sh...
#   0 5  * * *  ...pelagos run ... morning-on.sh...
#
# This script:
#   1. Caches that crontab verbatim to /etc/cluster-scheduler/crontab.default on
#      nazgul the first time it's run (so we always know how to restore it).
#   2. Installs a one-off crontab for *today only*: the night-off command moved to
#      the requested HH:MM, chained with a restore of crontab.default right after
#      it runs. The 05:00 morning-on line is carried over unchanged.
#
# Next night reverts to the standard 21:00 shutdown automatically -- no manual
# cleanup needed.
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

night_off_line=$(grep 'night-off.sh' "$default_file")
morning_on_line=$(grep 'morning-on.sh' "$default_file")

now_epoch=$(date +%s)
today=$(date +%Y-%m-%d)
target_epoch=$(date -d "$today $target_hhmm" +%s)

if (( target_epoch <= now_epoch )); then
    echo "error: $target_hhmm has already passed today (now is $(date +%H:%M)) -- nothing to defer" >&2
    exit 1
fi

day=$(date +%d)
month=$(date +%m)
night_off_cmd=${night_off_line#* }        # strip leading "0 21 * * *" (5 fields)
night_off_cmd=$(echo "$night_off_cmd" | cut -d' ' -f5-)

{
    echo "# one-off override installed $(date): tonight's shutdown moved to $target_hhmm"
    echo "$target_min $target_hour $day $month * $night_off_cmd; crontab $default_file"
    echo "$morning_on_line"
} > /tmp/crontab.override

crontab /tmp/crontab.override
rm -f /tmp/crontab.override

echo "==> tonight's shutdown moved to $target_hhmm (nazgul local time: $(date +%Z))"
echo "==> schedule reverts to the standard 21:00 shutdown automatically right after it runs"
crontab -l
REMOTE
