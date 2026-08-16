#!/usr/bin/env bash
# pushover-alert.sh "title" "message"
#
# Sends a Pushover notification DIRECTLY (not via Alertmanager) — deliberately
# so scheduler-script failures are still reported even when the monitoring
# stack itself is the thing that's down or unreachable. This is exactly the
# failure mode that let last night's shutdown fail silently (2026-08-15):
# silence-alerts.sh couldn't reach Alertmanager, the failure was swallowed by
# a bash `set -e`/command-substitution gotcha (exit inside `$(...)` only
# kills the subshell), and nothing ever told anyone the whole night-off.sh
# run had aborted before it ever reached shutdown-cluster.sh.
#
# Requires PUSHOVER_USER_KEY / PUSHOVER_API_TOKEN in the environment
# (sourced from --env-file /etc/cluster-scheduler/pushover.env in the cron
# invocation — see crontab -l on nazgul). Silently no-ops if unset, so a
# missing/misconfigured credential doesn't itself abort the calling script.
set -uo pipefail

TITLE="${1:?usage: pushover-alert.sh TITLE MESSAGE}"
MESSAGE="${2:?usage: pushover-alert.sh TITLE MESSAGE}"

if [[ -z "${PUSHOVER_USER_KEY:-}" || -z "${PUSHOVER_API_TOKEN:-}" ]]; then
    echo "pushover-alert.sh: PUSHOVER_USER_KEY/PUSHOVER_API_TOKEN not set, skipping notification" >&2
    exit 0
fi

curl -s --max-time 10 \
    --form-string "token=$PUSHOVER_API_TOKEN" \
    --form-string "user=$PUSHOVER_USER_KEY" \
    --form-string "title=$TITLE" \
    --form-string "message=$MESSAGE" \
    --form-string "priority=1" \
    https://api.pushover.net/1/messages.json >/dev/null \
    || echo "pushover-alert.sh: failed to send notification (network issue?)" >&2

exit 0
