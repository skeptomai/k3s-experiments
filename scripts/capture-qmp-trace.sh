#!/bin/bash
# Capture QMP traffic during virt-launcher domain create attempt.
# Sequence: start bpftrace on ipc8 → apply VMI → wait for failure → read trace.
set -euo pipefail

TRACELOG=/tmp/qmp-trace.log
BPFTRACE_SCRIPT=/tmp/bpftrace-qmp-traffic.bt

echo "[$(date +%T)] Copying bpftrace script to ipc8..."
scp -o ControlMaster=no -J cb@ipc4.taildd208.ts.net \
    scripts/bpftrace-qmp-traffic.bt cb@ipc8:/tmp/bpftrace-qmp-traffic.bt

echo "[$(date +%T)] Deleting any existing cirros-test VMI..."
kubectl delete vmi cirros-test --ignore-not-found 2>&1 || true

echo "[$(date +%T)] Waiting for old virt-launcher pods to clear..."
for i in $(seq 1 30); do
    COUNT=$(kubectl get pods -n default --no-headers 2>/dev/null | grep -c virt-launcher || true)
    [ "$COUNT" = "0" ] && break
    sleep 1
done

echo "[$(date +%T)] Starting bpftrace on ipc8 (capturing QMP traffic)..."
ssh -o ControlMaster=no -J cb@ipc4.taildd208.ts.net cb@ipc8 \
    "sudo bpftrace /tmp/bpftrace-qmp-traffic.bt > $TRACELOG 2>&1 &"

echo "[$(date +%T)] Waiting 4s for bpftrace to initialize..."
sleep 4

echo "[$(date +%T)] Applying VMI..."
kubectl apply -f experiments/25-kubevirt-vm/vmi-cirros.yaml

echo "[$(date +%T)] Waiting 25s for domain create attempts to complete..."
sleep 25

echo "[$(date +%T)] Stopping bpftrace on ipc8..."
ssh -o ControlMaster=no -J cb@ipc4.taildd208.ts.net cb@ipc8 \
    "sudo pkill -x bpftrace 2>/dev/null || true"

echo "[$(date +%T)] Reading trace log from ipc8..."
echo "=== QMP TRACE ==="
ssh -o ControlMaster=no -J cb@ipc4.taildd208.ts.net cb@ipc8 "cat $TRACELOG"
