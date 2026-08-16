#!/usr/bin/env bash
# silence-alerts.sh [on [DURATION] | off | night | status]
#
# Manages a global Alertmanager silence (mutes all alert notifications).
# Prometheus keeps scraping and evaluating rules; nothing fires while silenced.
#
# Usage:
#   silence-alerts.sh             # toggle (off if silent, on for 12h if not)
#   silence-alerts.sh on          # silence for 12h (default)
#   silence-alerts.sh on 4h       # silence for 4h (units: m, h, d)
#   silence-alerts.sh off         # remove active silence immediately
#   silence-alerts.sh night       # silence until 05:00 local time (for cron at 21:00)
#   silence-alerts.sh status      # show current silence state
#
# Exit status: 0 on success, 1 if Alertmanager was unreachable or any step
# failed. Callers (night-off.sh) MUST check this explicitly rather than
# relying on `set -e` alone -- see the big comment below for why.

set -uo pipefail
# Deliberately NOT `set -e` at the top level. Every helper below that talks
# to Alertmanager is invoked via `var=$(fn)` somewhere in the call chain
# (active_silence_id, create_silence, etc). Bash's `set -e` does NOT reliably
# abort on a failing command inside an assignment-context command
# substitution (`var=$(cmd)` -- a well-known POSIX/bash gotcha), and `exit`
# called from *inside* such a substitution only kills that subshell, not the
# script. Both bit us on 2026-08-15: Alertmanager was unreachable, `die()`
# was invoked from inside a `$(...)`, the script kept going with an empty
# variable, and an unrelated-looking Python JSONDecodeError was the only
# visible symptom -- the actual failure (can't reach Alertmanager) never
# stopped the script or propagated a nonzero exit to night-off.sh, so the
# whole night's shutdown silently never happened. Fix: every helper here
# returns (not exits) on failure, and every caller explicitly checks with
# `|| return 1` / `|| die`, all the way up to the dispatch at the bottom,
# so a real failure reliably produces a nonzero process exit status.

# The cluster-scheduler container runs with system TZ=UTC. "night"/"wake_time"
# are meant in local (Pacific) time, so all date arithmetic here must pin TZ
# explicitly — otherwise "05:30 today" resolves against the UTC calendar day,
# which can be only ~90 minutes away at 21:00 PDT instead of the intended
# ~8.5 hours, collapsing the night silence almost immediately.
export TZ="America/Los_Angeles"

ALERTMANAGER="http://192.168.89.2:9093"
CREATED_BY="silence-alerts.sh"
DEFAULT_DURATION="12h"

# ── helpers ────────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

# Prints the silences JSON on stdout and returns 0, or prints nothing and
# returns 1. Never calls die/exit itself -- callers decide what "can't reach
# Alertmanager" means for them (some can tolerate it, e.g. cmd_night should
# still report failure but the CALLER of this whole script, night-off.sh,
# is the one that decides whether to proceed with shutdown anyway).
am_get() {
    local body
    if ! body=$(curl -sf --max-time 10 "$ALERTMANAGER/api/v2/silences"); then
        echo "ERROR: Cannot reach Alertmanager at $ALERTMANAGER" >&2
        return 1
    fi
    echo "$body"
}

active_silence_id() {
    local body
    body=$(am_get) || return 1
    echo "$body" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if s.get('createdBy') == '$CREATED_BY' and s['status']['state'] == 'active':
        print(s['id'])
        break
"
}

parse_duration_secs() {
    local d="$1" num unit
    num="${d%[mhd]}"
    unit="${d: -1}"
    [[ "$num" =~ ^[0-9]+$ ]] || die "Invalid duration '$d' — use e.g. 30m, 4h, 2d"
    case "$unit" in
        m) echo $((num * 60)) ;;
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
        *) die "Invalid duration unit '$unit' in '$d' — use m, h, or d" ;;
    esac
}

night_ends_at() {
    local wake_time="${1:-05:30}" today tomorrow target now
    now=$(date +%s)
    today=$(date -d "$wake_time today" +%s)
    tomorrow=$(date -d "$wake_time tomorrow" +%s)
    if [[ $now -ge $today ]]; then
        target=$tomorrow
    else
        target=$today
    fi
    date -u -d "@$target" +"%Y-%m-%dT%H:%M:%SZ"
}

# Prints the new silence ID on stdout and returns 0, or prints nothing and
# returns 1 (see am_get's comment -- same reasoning).
create_silence() {
    local ends_at="$1" comment="$2"
    local now result
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    if ! result=$(curl -sf --max-time 10 -X POST "$ALERTMANAGER/api/v2/silences" \
        -H "Content-Type: application/json" \
        -d "{
            \"matchers\": [{\"name\": \"alertname\", \"value\": \".+\", \"isRegex\": true}],
            \"startsAt\": \"$now\",
            \"endsAt\": \"$ends_at\",
            \"createdBy\": \"$CREATED_BY\",
            \"comment\": \"$comment\"
        }"); then
        echo "ERROR: Failed to create silence (Alertmanager unreachable or rejected the request)" >&2
        return 1
    fi
    echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['silenceID'])"
}

delete_silence() {
    local id="$1"
    if ! curl -sf --max-time 10 -X DELETE "$ALERTMANAGER/api/v2/silence/$id" >/dev/null; then
        echo "ERROR: Failed to delete silence $id" >&2
        return 1
    fi
}

show_status() {
    local id body
    id=$(active_silence_id) || return 1
    if [[ -z "$id" ]]; then
        echo "ALERTS ACTIVE (no silence)"
        return 0
    fi
    body=$(am_get) || return 1
    echo "$body" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if s['id'] == '$id':
        print('SILENCED  id=' + s['id'])
        print('  ends:  ' + s['endsAt'])
        print('  note:  ' + s['comment'])
        break
"
}

# ── subcommands ────────────────────────────────────────────────────────────────
# Each cmd_* function returns nonzero on any failure in its chain -- this is
# what the dispatch at the bottom relies on to produce the script's final
# exit status, since these are the last commands run (no extra subshell
# wrapping there).

cmd_on() {
    local duration="${1:-$DEFAULT_DURATION}" secs ends_at id
    secs=$(parse_duration_secs "$duration") || return 1
    ends_at=$(date -u -d "+${secs} seconds" +"%Y-%m-%dT%H:%M:%SZ")
    id=$(create_silence "$ends_at" "Manual silence for $duration") || return 1
    echo "Silenced for $duration (until $(date -d "$ends_at") local) — id=$id"
    echo "  Remove early: $0 off"
}

cmd_off() {
    local id
    id=$(active_silence_id) || return 1
    if [[ -z "$id" ]]; then
        echo "No active silence to remove."
        return 0
    fi
    delete_silence "$id" || return 1
    echo "Silence removed — alerts are active."
}

cmd_night() {
    local wake_time="${1:-05:30}" ends_at id existing
    existing=$(active_silence_id) || return 1
    if [[ -n "$existing" ]]; then
        echo "Already silenced (id=$existing). Remove with: $0 off"
        show_status
        return 0
    fi
    ends_at=$(night_ends_at "$wake_time")
    id=$(create_silence "$ends_at" "Night silence (21:00–${wake_time})") || return 1
    echo "Night silence active until $(date -d "$ends_at") local — id=$id"
}

cmd_toggle() {
    local id
    id=$(active_silence_id) || return 1
    if [[ -n "$id" ]]; then
        delete_silence "$id" || return 1
        echo "Silence removed — alerts are active."
    else
        cmd_on "$DEFAULT_DURATION" || return 1
    fi
}

# ── dispatch ───────────────────────────────────────────────────────────────────

case "${1:-toggle}" in
    on)     cmd_on "${2:-}" ;;
    off)    cmd_off ;;
    night)  cmd_night "${2:-}" ;;
    status) show_status ;;
    toggle) cmd_toggle ;;
    *)      die "Unknown command '$1'. Use: on [DURATION] | off | night | status | toggle" ;;
esac
