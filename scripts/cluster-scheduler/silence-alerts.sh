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

set -euo pipefail

ALERTMANAGER="http://192.168.89.2:9093"
CREATED_BY="silence-alerts.sh"
DEFAULT_DURATION="12h"

# ── helpers ────────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

am_get() { curl -sf "$ALERTMANAGER/api/v2/silences" || die "Cannot reach Alertmanager at $ALERTMANAGER"; }

active_silence_id() {
    am_get | python3 -c "
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

create_silence() {
    local ends_at="$1" comment="$2"
    local now result
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    result=$(curl -sf -X POST "$ALERTMANAGER/api/v2/silences" \
        -H "Content-Type: application/json" \
        -d "{
            \"matchers\": [{\"name\": \"alertname\", \"value\": \".+\", \"isRegex\": true}],
            \"startsAt\": \"$now\",
            \"endsAt\": \"$ends_at\",
            \"createdBy\": \"$CREATED_BY\",
            \"comment\": \"$comment\"
        }") || die "Failed to create silence"
    echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['silenceID'])"
}

delete_silence() {
    local id="$1"
    curl -sf -X DELETE "$ALERTMANAGER/api/v2/silence/$id" >/dev/null \
        || die "Failed to delete silence $id"
}

show_status() {
    local id
    id=$(active_silence_id)
    if [[ -z "$id" ]]; then
        echo "ALERTS ACTIVE (no silence)"
        return
    fi
    am_get | python3 -c "
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

cmd_on() {
    local duration="${1:-$DEFAULT_DURATION}" secs ends_at id
    secs=$(parse_duration_secs "$duration")
    ends_at=$(date -u -d "+${secs} seconds" +"%Y-%m-%dT%H:%M:%SZ")
    id=$(create_silence "$ends_at" "Manual silence for $duration")
    echo "Silenced for $duration (until $(date -d "$ends_at") local) — id=$id"
    echo "  Remove early: $0 off"
}

cmd_off() {
    local id
    id=$(active_silence_id)
    if [[ -z "$id" ]]; then
        echo "No active silence to remove."
        return
    fi
    delete_silence "$id"
    echo "Silence removed — alerts are active."
}

cmd_night() {
    local wake_time="${1:-05:30}" ends_at id existing
    existing=$(active_silence_id)
    if [[ -n "$existing" ]]; then
        echo "Already silenced (id=$existing). Remove with: $0 off"
        show_status
        return
    fi
    ends_at=$(night_ends_at "$wake_time")
    id=$(create_silence "$ends_at" "Night silence (21:00–${wake_time})")
    echo "Night silence active until $(date -d "$ends_at") local — id=$id"
}

cmd_toggle() {
    local id
    id=$(active_silence_id)
    if [[ -n "$id" ]]; then
        delete_silence "$id"
        echo "Silence removed — alerts are active."
    else
        cmd_on "$DEFAULT_DURATION"
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
