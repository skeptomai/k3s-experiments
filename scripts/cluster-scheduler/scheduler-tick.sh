#!/usr/bin/env bash
# scheduler-tick.sh -- runs every minute via nazgul's plain system cron.
# Not containerized: this script lives and runs directly on the host, so
# its state (the once-per-day fire markers) persists naturally without any
# bind-mount gymnastics, and it's cheap enough to run 1440x/day with zero
# meaningful overhead (a date comparison and a file read, nothing else).
#
# Why this exists (2026-10-11): Debian's stock `cron` package has no
# CRON_TZ support at all -- confirmed via crontab(5), which says a TZ= line
# "will affect only the commands executed in the crontab, not the execution
# of the crontab tasks themselves". cronie supports it properly but is
# Debian-experimental-only (not available on bookworm without adding an
# unstable repo to this NAS's base OS -- rejected). Changing nazgul's own
# system timezone was also explicitly rejected (shared US-based machine,
# other things on it may reasonably assume the system clock). A hardcoded
# Pacific-equivalent offset in the crontab's numeric fields was rejected
# too -- UK and US DST transitions land on different dates, so that's wrong
# for ~2 weeks every spring and fall.
#
# This sidesteps all three constraints: cron keeps firing on the system
# clock (irrelevant now, since this script does its own TZ-aware check),
# and the actual time math happens here via `TZ=Europe/London date`, which
# handles DST transitions automatically and correctly via tzdata -- no
# manual adjustment, ever, in either direction.
set -euo pipefail

STATE_DIR="/etc/cluster-scheduler"
TODAY=$(TZ=Europe/London date +%Y-%m-%d)
# `10#` forces base-10 interpretation -- without it, bash arithmetic treats
# a leading-zero string like "0500" as octal, which is still numerically
# valid-looking (0,5,0,0 are all legal octal digits) but silently computes
# the WRONG number instead of erroring, which would have been a nasty, hard
# -to-notice bug the first time this ran at 05:0x.
NOW_HM=$((10#$(TZ=Europe/London date +%H%M)))

# Each action gets a few minutes' grace window (not an exact-single-minute
# match) so a transient cron/system hiccup around the target minute doesn't
# silently skip the whole day -- any tick landing in the window fires it
# once, guarded by the marker file.
in_window() {
    local start="$1" end="$2"
    [[ "$NOW_HM" -ge "$start" && "$NOW_HM" -le "$end" ]]
}

fire_once_per_day() {
    local marker="$STATE_DIR/$1" label="$2"; shift 2
    if [[ "$(cat "$marker" 2>/dev/null)" == "$TODAY" ]]; then
        return 0  # already fired today, this is just another tick inside the window
    fi
    echo "$TODAY" > "$marker"
    echo "==> [$(TZ=Europe/London date)] tick: firing $label"
    "$@"
}

run_night_off() {
    pelagos run --rm --network=bridge --env TZ=Europe/London \
        --bind-ro /root/.ssh/id_rsa:/root/.ssh/id_rsa \
        --bind-ro /etc/cluster-scheduler/kubeconfig:/etc/cluster-scheduler/kubeconfig \
        --env-file /etc/cluster-scheduler/pushover.env \
        localhost:5004/cluster-scheduler:latest /scripts/night-off.sh
}

run_morning_on() {
    pelagos run --rm --network=bridge --env TZ=Europe/London \
        --bind-ro /root/.ssh/id_rsa:/root/.ssh/id_rsa \
        --bind-ro /etc/cluster-scheduler/kubeconfig:/etc/cluster-scheduler/kubeconfig \
        --env-file /etc/cluster-scheduler/pushover.env \
        localhost:5004/cluster-scheduler:latest /scripts/morning-on.sh
}

run_descheduler_alert() {
    pelagos run --rm --network=bridge --env TZ=Europe/London \
        --bind-ro /etc/cluster-scheduler/kubeconfig:/etc/cluster-scheduler/kubeconfig \
        --env-file /etc/cluster-scheduler/pushover.env \
        localhost:5004/cluster-scheduler:latest /scripts/descheduler-alert.sh
}

# One-off overrides (set-shutdown-time.sh / set-startup-time.sh) write a
# "$TODAY $HH:MM" line to one of these files instead of touching crontab --
# crontab carries no scheduling information at all any more, so there's
# nothing in it to override. Reads the file, and if it's dated today,
# returns a 5-minute window starting at that HH:MM instead of the default.
# A stale (not-today) override is lazily deleted the next time it's
# checked, rather than needing an active revert step -- state, not TTL:
# "is there an override for *today* specifically" is just a date
# comparison, so it can't linger past the day it was meant for.
window_for() {
    local override_file="$STATE_DIR/$1" default_start="$2" default_end="$3"
    if [[ -f "$override_file" ]]; then
        local ov_date ov_hhmm
        read -r ov_date ov_hhmm < "$override_file"
        if [[ "$ov_date" == "$TODAY" ]]; then
            local ov_start=$((10#${ov_hhmm%%:*} * 100 + 10#${ov_hhmm##*:}))
            echo "$ov_start $((ov_start + 4))"
            return
        fi
        rm -f "$override_file"
    fi
    echo "$default_start $default_end"
}

read -r night_off_start night_off_end <<< "$(window_for .override-night-off 2100 2104)"
read -r morning_on_start morning_on_end <<< "$(window_for .override-morning-on 500 504)"

if in_window "$night_off_start" "$night_off_end"; then
    fire_once_per_day .last-night-off "night-off" run_night_off
elif in_window "$morning_on_start" "$morning_on_end"; then
    fire_once_per_day .last-morning-on "morning-on" run_morning_on
elif in_window 520 524; then
    fire_once_per_day .last-descheduler-alert "descheduler-alert" run_descheduler_alert
fi
