#!/usr/bin/env bash
# descheduler-alert.sh
#
# Reminder to review the descheduler's dry-run logs each morning. It runs at
# 05:10 America/Los_Angeles, right after morning-on.sh's uncordon burst --
# see manifests/descheduler/helmrelease.yaml and
# docs/ipc4-pod-pileup-postmortem.md for why it exists. Pulls the most
# recent Job's pod logs, counts eviction-related lines, and sends a Pushover
# summary so there's actually something to act on rather than a blind
# "go check" ping.
#
# Deliberately stays a reminder, not automation: flipping dry-run off is a
# manual decision (dry-run: false in manifests/descheduler/helmrelease.yaml,
# after actually agreeing with what it would have evicted), not something
# this script does on its own.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSHOVER="$SCRIPT_DIR/pushover-alert.sh"
export KUBECONFIG=/etc/cluster-scheduler/kubeconfig

JOB=$(kubectl get jobs -n descheduler -l app.kubernetes.io/name=descheduler \
    --sort-by=.status.startTime -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)

if [[ -z "$JOB" ]]; then
    "$PUSHOVER" "descheduler: no job found" \
        "Expected a descheduler CronJob run around 05:10 but found no Job in the descheduler namespace. Check: kubectl get cronjob -n descheduler"
    exit 0
fi

# Wait up to 3 minutes for the job to finish if it's still running.
for _ in $(seq 1 18); do
    STATUS=$(kubectl get job -n descheduler "$JOB" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null)
    [[ -n "$STATUS" ]] && break
    sleep 10
done

LOGS=$(kubectl logs -n descheduler -l "job-name=$JOB" --tail=1000 2>&1)
EVICT_LINES=$(echo "$LOGS" | grep -i "evict" || true)
COUNT=$(printf '%s\n' "$EVICT_LINES" | grep -c . || true)

if [[ "$COUNT" -eq 0 ]]; then
    SUMMARY="No eviction-related log lines found -- cluster looked balanced to it this morning."
else
    SUMMARY="$COUNT eviction-related line(s) logged. Sample:
$(printf '%s\n' "$EVICT_LINES" | head -5)"
fi

"$PUSHOVER" "descheduler: review dry-run logs ($JOB)" \
    "$SUMMARY

Full logs: kubectl logs -n descheduler -l job-name=$JOB --tail=200
When satisfied, flip dry-run: false in manifests/descheduler/helmrelease.yaml"
