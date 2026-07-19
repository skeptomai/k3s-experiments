#!/bin/bash
# run-trial.sh <trial-number> <unpatched|patched>
# Runs one attestation trial on ipc9 with bpftrace capturing TPM call timing.
# ipc9 must already be isolated (production DaemonSet excluded via nodeAffinity).
set -euo pipefail

TRIAL=$1
VARIANT=$2
OUTDIR="$(dirname "$0")/trial-results"
mkdir -p "$OUTDIR"

MANIFEST="$(dirname "$0")/test-${VARIANT}.yaml"
DSNAME="spire-agent-trial-${VARIANT}"
NS="spire"
BTOUT="$OUTDIR/trial-${TRIAL}-${VARIANT}.bt"
RESULTOUT="$OUTDIR/trial-${TRIAL}-${VARIANT}.log"
BPFTRACE_SCRIPT="/tmp/bpftrace-spire-tpm-stall.bt"  # pre-copied to ipc9 via scp

echo "=== Trial $TRIAL ($VARIANT) ===" | tee "$RESULTOUT"
echo "Start: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$RESULTOUT"

# Pre-trial TPM state check
echo "--- TPM state (pre) ---" | tee -a "$RESULTOUT"
ssh ipc4.taildd208.ts.net "ssh ipc9 'sudo tpm2_getcap handles-persistent'" 2>/dev/null | tee -a "$RESULTOUT"

# Start bpftrace on ipc9 in background
ssh ipc4.taildd208.ts.net "ssh ipc9 'sudo bpftrace $BPFTRACE_SCRIPT > /tmp/trial-${TRIAL}-${VARIANT}.bt 2>&1 & echo \$!'" > /tmp/bt-pid-${TRIAL} 2>/dev/null
BTPID=$(cat /tmp/bt-pid-${TRIAL})
echo "bpftrace PID on ipc9: $BTPID" | tee -a "$RESULTOUT"
sleep 2  # let bpftrace initialise

# Deploy test DaemonSet
kubectl apply -f "$MANIFEST" >/dev/null
echo "DaemonSet applied at $(date -u +%H:%M:%SZ)" | tee -a "$RESULTOUT"

# Wait for pod Running
until kubectl get pod -n "$NS" -l "app=$DSNAME" -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; do sleep 3; done
POD=$(kubectl get pod -n "$NS" -l "app=$DSNAME" -o jsonpath='{.items[0].metadata.name}')
echo "Pod running: $POD" | tee -a "$RESULTOUT"

# Wait for attestation result
until kubectl logs -n "$NS" "$POD" -c spire-agent 2>/dev/null | grep -qE 'Node attestation was successful|Agent crashed'; do sleep 3; done

# Grab timing from logs
kubectl logs -n "$NS" "$POD" -c spire-agent 2>/dev/null \
  | grep -E 'Starting node attestation|Node attestation was successful|Agent crashed' \
  | tee -a "$RESULTOUT"

# Kill bpftrace and collect output
ssh ipc4.taildd208.ts.net "ssh ipc9 'sudo kill $BTPID 2>/dev/null; sleep 1; cat /tmp/trial-${TRIAL}-${VARIANT}.bt'" > "$BTOUT" 2>/dev/null
echo "bpftrace output: $BTOUT ($(wc -l < "$BTOUT") lines)" | tee -a "$RESULTOUT"

# Summarise CreatePrimary calls from bpftrace output
echo "--- CreatePrimary calls (read() duration > 5s) ---" | tee -a "$RESULTOUT"
grep "SLOW\|read() returned" "$BTOUT" | tee -a "$RESULTOUT" || echo "(none captured)" | tee -a "$RESULTOUT"

# Delete DaemonSet and wait for pod to terminate
kubectl delete -f "$MANIFEST" >/dev/null
until ! kubectl get pod -n "$NS" -l "app=$DSNAME" 2>/dev/null | grep -q "$DSNAME"; do sleep 3; done
echo "Pod terminated" | tee -a "$RESULTOUT"

# Post-trial TPM state check
echo "--- TPM state (post) ---" | tee -a "$RESULTOUT"
ssh ipc4.taildd208.ts.net "ssh ipc9 'sudo tpm2_getcap handles-persistent'" 2>/dev/null | tee -a "$RESULTOUT"

echo "End: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$RESULTOUT"
echo "=== Trial $TRIAL done ===" | tee -a "$RESULTOUT"
