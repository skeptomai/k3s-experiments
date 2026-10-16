#!/usr/bin/env bash
# silence-alerts.sh <on [DURATION] | off | night | status | toggle>
#
# Manages a global Alertmanager silence (mutes all alert notifications).
# Prometheus keeps scraping and evaluating rules; nothing fires while silenced.
#
# Usage:
#   silence-alerts.sh on          # silence for 12h (default)
#   silence-alerts.sh on 4h       # silence for 4h (units: m, h, d)
#   silence-alerts.sh off         # remove active silence immediately
#   silence-alerts.sh night       # silence until 05:30 Europe/London (for the
#                                 # manual cluster-night-off.sh wrapper)
#   silence-alerts.sh status      # show current silence state
#   silence-alerts.sh toggle      # off if silent, on for 12h if not -- explicit
#                                 # only, see the no-argument note below
#
# WHY A SEPARATE COPY FROM scripts/cluster-scheduler/silence-alerts.sh:
# that one runs *inside* the nazgul-hosted Pelagos container as part of the
# real automated night-off/morning-on cron cycle (see
# docs/cluster-night-mode.md). This one is what
# scripts/cluster-night-off.sh/cluster-morning-on.sh (the manual,
# run-it-yourself wrappers) actually call -- directly, on whatever machine
# you run them from, no SSH/container/nazgul dependency. They diverged for
# a while (2026-08-15's error-handling fix and other improvements landed
# in the container copy but never got backported here) before being
# brought back to parity 2026-10-16 -- diff the two if you're ever unsure
# whether "the same fix" needs to land in both places; it usually does.
#
# PORTABILITY: this runs on whatever machine you invoke it from -- omen
# (x86_64 Linux, GNU date natively) or any other dev machine including an
# Apple Silicon Mac (BSD date, no `-d` flag at all -- confirmed the hard
# way testing this exact script). Detects and uses `gdate` (GNU coreutils,
# `brew install coreutils` on macOS) when the native `date` doesn't
# understand `-d`, rather than assuming a specific OS.
set -uo pipefail
# Deliberately NOT `set -e` at the top level, matching
# scripts/cluster-scheduler/silence-alerts.sh. Every helper below that
# talks to Alertmanager is invoked via `var=$(fn)` somewhere in the call
# chain. Bash's `set -e` does NOT reliably abort on a failing command
# inside an assignment-context command substitution (`var=$(cmd)` -- a
# well-known POSIX/bash gotcha), and `exit` called from *inside* such a
# substitution only kills that subshell, not the script. This exact thing
# bit the container copy for real on 2026-08-15: Alertmanager was
# unreachable, `die()` was invoked from inside a `$(...)`, the script kept
# going with an empty variable, and an unrelated-looking Python
# JSONDecodeError was the only visible symptom -- the actual failure
# never stopped the script or propagated a nonzero exit to the caller, so
# a whole night's shutdown silently never happened. Fix, same here as
# there: every helper returns (not exits) on failure, every caller
# explicitly checks with `|| return 1` / `|| die`, all the way up to the
# dispatch at the bottom, so a real failure reliably produces a nonzero
# process exit status.

if date --version >/dev/null 2>&1; then
    DATE_CMD="date"
elif command -v gdate >/dev/null 2>&1; then
    DATE_CMD="gdate"
else
    echo "ERROR: need a GNU-compatible 'date -d' -- found neither on this machine." >&2
    echo "  On macOS: brew install coreutils (provides gdate)." >&2
    exit 1
fi

# Pinned to the cluster's own schedule timezone, not wherever this script
# happens to be run from -- "night"/"wake_time" math (e.g. "05:30 today")
# must mean 05:30 in the same terms the cluster's real automated schedule
# (scheduler-tick.sh on nazgul) is anchored to, regardless of which
# machine or which timezone *you* currently are in. Parametrized (honors
# an already-exported TZ) rather than hardcoded, same reasoning as the
# container copy: changing the cluster's schedule timezone shouldn't
# require editing this script too, just whatever sets TZ before calling it.
export TZ="${TZ:-Europe/London}"

ALERTMANAGER="http://192.168.89.2:9093"
CREATED_BY="silence-alerts.sh"
DEFAULT_DURATION="12h"

# ── helpers ────────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

# Prints the silences JSON on stdout and returns 0, or prints nothing and
# returns 1. Never calls die/exit itself -- callers decide what "can't
# reach Alertmanager" means for them.
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
    [[ "$num" =~ ^[0-9]+$ ]] || { echo "ERROR: Invalid duration '$d' — use e.g. 30m, 4h, 2d" >&2; return 1; }
    case "$unit" in
        m) echo $((num * 60)) ;;
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
        *) echo "ERROR: Invalid duration unit '$unit' in '$d' — use m, h, or d" >&2; return 1 ;;
    esac
}

night_ends_at() {
    local wake_time="${1:-05:30}" today tomorrow target now
    now=$("$DATE_CMD" +%s)
    today=$("$DATE_CMD" -d "$wake_time today" +%s)
    tomorrow=$("$DATE_CMD" -d "$wake_time tomorrow" +%s)
    if [[ $now -ge $today ]]; then
        target=$tomorrow
    else
        target=$today
    fi
    "$DATE_CMD" -u -d "@$target" +"%Y-%m-%dT%H:%M:%SZ"
}

# Prints the new silence ID on stdout and returns 0, or prints nothing and
# returns 1 (see am_get's comment -- same reasoning).
create_silence() {
    local ends_at="$1" comment="$2"
    local now result
    now=$("$DATE_CMD" -u +"%Y-%m-%dT%H:%M:%SZ")
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
# Each cmd_* function returns nonzero on any failure in its chain -- the
# dispatch at the bottom relies on this to produce the script's final exit
# status, since these are the last commands run (no extra subshell
# wrapping there).

cmd_on() {
    local duration="${1:-$DEFAULT_DURATION}" secs ends_at id
    secs=$(parse_duration_secs "$duration") || return 1
    ends_at=$("$DATE_CMD" -u -d "+${secs} seconds" +"%Y-%m-%dT%H:%M:%SZ")
    id=$(create_silence "$ends_at" "Manual silence for $duration") || return 1
    echo "Silenced for $duration (until $("$DATE_CMD" -d "$ends_at") local) — id=$id"
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
    echo "Night silence active until $("$DATE_CMD" -d "$ends_at") local — id=$id"
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
# A bare invocation with NO argument is a usage error (prints usage, exits
# 1) -- it used to default to `toggle`, which meant the outcome of running
# this with no argument depended on hidden current state (was something
# already silenced?) that the caller couldn't see without checking first.
# Removed 2026-10-10 after exactly that bit once: an unrelated sanity-check
# command (`source silence-alerts.sh` with no arg, meant to just test an
# env-var fallback) silently toggled off a real, legitimate night silence
# because one happened to be active at that moment -- never intended as a
# mutation, looked harmless, wasn't. `toggle` is still available by
# explicit name for whoever genuinely wants flip-based convenience; only
# the *implicit* no-argument default was the problem, not the mode itself.
case "${1:-}" in
    on)     cmd_on "${2:-}" ;;
    off)    cmd_off ;;
    night)  cmd_night "${2:-}" ;;
    status) show_status ;;
    toggle) cmd_toggle ;;
    *)      die "Usage: $0 <on [DURATION] | off | night | status | toggle> -- no argument is a usage error, not a default action." ;;
esac
