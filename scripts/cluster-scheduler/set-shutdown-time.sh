#!/usr/bin/env bash
# Defers tonight's automated cluster shutdown to a different America/Los_Angeles
# time, without permanently changing the standing 21:00 schedule.
#
# 2026-10-11: rewritten against scheduler-tick.sh's model (see
# docs/cluster-night-mode.md's "Timezone" section). nazgul's crontab no
# longer carries any scheduling information (just `* * * * *
# scheduler-tick.sh`), so there is nothing in it to override any more --
# the old mechanism (install a one-off numbered crontab entry, chained
# with a restore) depended entirely on crontab lines that don't exist.
#
# This just writes a "$TODAY $HH:MM" line to
# /etc/cluster-scheduler/.override-night-off on nazgul.
# scheduler-tick.sh checks that file every minute and, if its date matches
# today, uses that time instead of the standard 21:00 window. Self-expires
# naturally: tomorrow the stored date no longer matches "today", so the
# override is just ignored (and lazily deleted the next time
# scheduler-tick.sh checks it) -- no explicit revert step needed, state
# rather than a TTL.
set -euo pipefail

NAZGUL="root@nazgul.taildd208.ts.net"
OVERRIDE_FILE="/etc/cluster-scheduler/.override-night-off"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <HH:MM>  (24hr, America/Los_Angeles)" >&2
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

today=$(TZ=America/Los_Angeles date +%Y-%m-%d)
now_hm=$((10#$(TZ=America/Los_Angeles date +%H%M)))
target_hm=$((10#$(echo "$target_hhmm" | tr -d ':')))

if (( target_hm <= now_hm )); then
    echo "error: $target_hhmm has already passed today (now is $(TZ=America/Los_Angeles date +%H:%M) America/Los_Angeles) -- nothing to defer" >&2
    exit 1
fi

mkdir -p "$(dirname "$override_file")"
echo "$today $target_hhmm" > "$override_file"
echo "==> tonight's shutdown moved to $target_hhmm America/Los_Angeles"
echo "==> reverts to the standard 21:00 shutdown automatically tomorrow (override is dated to today only)"
REMOTE
