#!/bin/bash
# run-all-trials.sh
# Isolates ipc9, runs interleaved unpatched/patched trials, then restores.
# Trials: 1=unpatched 2=patched 3=unpatched 4=patched
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
IPC9="ipc4.taildd208.ts.net"
BPFTRACE_SRC="/home/cb/Projects/k3s-experiments/scripts/bpftrace-spire-tpm-stall.bt"
COOLDOWN=60

echo ">>> Isolating ipc9"
# Exclude ipc9 from production spire-agent DaemonSet via nodeAffinity
kubectl patch daemonset -n spire spire-agent --type=merge -p '{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"kubernetes.io/hostname","operator":"NotIn","values":["ipc9"]}]}]}}}}}}}'
# Taint ipc9 to block other workloads
kubectl taint node ipc9 spire-test=true:NoSchedule --overwrite

echo ">>> Waiting for production spire-agent pod on ipc9 to terminate"
until ! kubectl get pod -n spire -l app=spire-agent --field-selector spec.nodeName=ipc9 2>/dev/null | grep -q Running; do sleep 3; done
echo ">>> ipc9 clear"

echo ">>> Copying bpftrace script to ipc9"
scp -J cb@ipc4.taildd208.ts.net "$BPFTRACE_SRC" cb@ipc9:/tmp/bpftrace-spire-tpm-stall.bt

SEQUENCE=(unpatched patched unpatched patched)
TRIAL=1

for VARIANT in "${SEQUENCE[@]}"; do
    echo ""
    echo ">>> Starting trial $TRIAL ($VARIANT) at $(date +%H:%M:%S)"
    bash "$SCRIPT_DIR/run-trial.sh" "$TRIAL" "$VARIANT"
    TRIAL=$((TRIAL + 1))
    if [ $TRIAL -le ${#SEQUENCE[@]} ]; then
        echo ">>> Cooldown ${COOLDOWN}s"
        sleep "$COOLDOWN"
    fi
done

echo ""
echo ">>> Restoring ipc9"
kubectl taint node ipc9 spire-test=true:NoSchedule-
kubectl patch daemonset -n spire spire-agent --type=merge -p '{"spec":{"template":{"spec":{"affinity":null}}}}'

echo ">>> Waiting for production spire-agent to reschedule on ipc9"
until kubectl get pod -n spire -l app=spire-agent --field-selector spec.nodeName=ipc9 2>/dev/null | grep -q Running; do sleep 3; done
echo ">>> Production agent back on ipc9"

echo ""
echo "ALL TRIALS COMPLETE at $(date +%H:%M:%S)"
