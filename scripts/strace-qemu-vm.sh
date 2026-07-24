#!/bin/bash
# Strace the ACTUAL VM QEMU (not the probe), catching all failed syscalls.
# Run on the target node as root BEFORE applying the VMI.
# The probe QEMU has -daemonize in its cmdline; the real VM QEMU does not.

set -euo pipefail

OUTFILE="/tmp/strace-qemu-vm-$(date +%s).log"
echo "Output: $OUTFILE"
echo "Waiting for VM QEMU (non-probe)..."

# First wait for probe QEMU to appear and finish
for i in $(seq 1 120); do
    PROBE=$(pgrep -f -- '-daemonize' 2>/dev/null || true)
    [ -n "$PROBE" ] && { echo "Probe QEMU PID=$PROBE found, waiting for it to exit..."; break; }
    sleep 0.1
done
if [ -n "$PROBE" ]; then
    timeout 10 tail --pid="$PROBE" -f /dev/null 2>/dev/null || true
    echo "Probe QEMU exited"
fi

echo "Now watching for actual VM QEMU..."
QPID=""
for i in $(seq 1 200); do
    for pid in $(pgrep -x qemu-kvm 2>/dev/null || true); do
        cmdline=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null || true)
        if ! echo "$cmdline" | grep -q '\-daemonize'; then
            QPID=$pid
            break 2
        fi
    done
    sleep 0.05
done

if [ -z "$QPID" ]; then
    echo "ERROR: actual VM QEMU never appeared"
    exit 1
fi
echo "Found actual VM QEMU PID=$QPID"

# Strace it: all syscalls, follow children, timestamps, show fd paths, only failures
timeout 10 strace -f -tt -y -e status=failed -e trace=all -p "$QPID" 2>&1 | tee "$OUTFILE" || true

echo ""
echo "=== FAILED SYSCALLS ==="
cat "$OUTFILE" | grep -v '^$' | head -200
