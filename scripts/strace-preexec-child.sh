#!/bin/bash
# Strace virtqemud and all forks to catch what the QEMU pre-exec child does
# before it exits without exec'ing.
#
# IMPORTANT: Run this BEFORE applying the VMI and ensure no virtqemud is
# currently running (i.e., the VMI pod is down). The script waits for an
# existing virtqemud to die, then waits for a fresh one, then attaches.
#
# Usage on the target node (ipc8):
#   Step 1: ssh -J cb@ipc4.taildd208.ts.net cb@ipc8 "sudo bash /tmp/strace-preexec-child.sh > /tmp/preexec.log 2>&1 &"
#   Step 2: kubectl apply -f experiments/25-kubevirt-vm/vmi-cirros.yaml
#   Step 3 (after ~10s): ssh ... "cat /tmp/preexec.log"

set -euo pipefail

OUTFILE="/tmp/strace-preexec-$(date +%s).log"
echo "Output -> $OUTFILE"

# Step 1: if virtqemud is already running, wait for it to die
EXISTING=$(pgrep -x virtqemud 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
    echo "Existing virtqemud PID=$EXISTING — waiting for it to die..."
    for i in $(seq 1 300); do
        STILL=$(pgrep -x virtqemud 2>/dev/null || true)
        [ -z "$STILL" ] && break
        sleep 0.1
    done
    STILL=$(pgrep -x virtqemud 2>/dev/null || true)
    if [ -n "$STILL" ]; then
        echo "ERROR: old virtqemud (PID=$STILL) still alive after 30s"
        exit 1
    fi
    echo "Old virtqemud gone."
fi

# Step 2: wait for a fresh virtqemud
echo "Waiting for fresh virtqemud..."
PID=""
for i in $(seq 1 300); do
    PID=$(pgrep -x virtqemud 2>/dev/null || true)
    [ -n "$PID" ] && break
    sleep 0.1
done

if [ -z "$PID" ]; then
    echo "ERROR: no virtqemud appeared within 30s"
    exit 1
fi
echo "Found fresh virtqemud PID=$PID, attaching strace..."

# Step 3: Wait briefly for virtqemud to finish daemonizing (parent forks child,
# parent exits; we want the stable child). Then gather ALL surviving virtqemud PIDs.
sleep 1
ALL_PIDS=$(pgrep -x virtqemud 2>/dev/null || true)
if [ -z "$ALL_PIDS" ]; then
    echo "ERROR: virtqemud disappeared after 1s (daemonize race)"
    exit 1
fi
echo "Stable virtqemud PID(s): $ALL_PIDS"

# Build -p args for all PIDs
STRACE_P_ARGS=""
for P in $ALL_PIDS; do
    STRACE_P_ARGS="$STRACE_P_ARGS -p $P"
done
echo "strace args: $STRACE_P_ARGS"

# Strace with fork-following, all syscalls relevant to the pre-exec phase
timeout 60 strace -f -tt -y \
    -e trace=execve,dup2,dup3,close,openat,open,read,write,fcntl,capset,capget,setuid,setgid,setgroups,prctl,pipe,pipe2,clone,clone3,exit,exit_group \
    $STRACE_P_ARGS 2>&1 | tee "$OUTFILE" || true

echo ""
echo "=== Summary: processes that exited without exec'ing ==="
python3 - "$OUTFILE" <<'PYEOF'
import sys, re

pids_exec = set()
pids_exit = {}
pids_lines = {}

with open(sys.argv[1]) as f:
    for line in f:
        m = re.search(r'\[pid\s+(\d+)\].*execve\(', line)
        if m:
            pids_exec.add(m.group(1))
        m2 = re.search(r'\[pid\s+(\d+)\].*exit_group\((\d+)\)', line)
        if m2:
            pids_exit[m2.group(1)] = m2.group(2)
        m3 = re.search(r'\[pid\s+(\d+)\]', line)
        if m3:
            pid = m3.group(1)
            pids_lines.setdefault(pid, []).append(line.rstrip())

no_exec = {p: c for p, c in pids_exit.items() if p not in pids_exec}
if no_exec:
    print("PIDs that exited without exec (pre-exec children):")
    for pid, code in sorted(no_exec.items()):
        print(f"  PID {pid} exit_group({code})")
        print(f"  Last 30 syscalls:")
        for l in pids_lines.get(pid, [])[-30:]:
            print("   ", l)
else:
    print("No exited-without-exec PIDs found.")
    print(f"Total PIDs seen: {sorted(pids_lines.keys())}")
    print(f"PIDs that exec'd: {sorted(pids_exec)}")
    print(f"PIDs that exited: {sorted(pids_exit.keys())}")
PYEOF
