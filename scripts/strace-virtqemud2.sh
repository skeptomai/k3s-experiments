#!/bin/bash
# Strace virtqemud from first appearance, following forks, catching all failures.
# Run on target node as root BEFORE applying the VMI.

set -euo pipefail

OUTFILE="/tmp/strace-virtqemud-$(date +%s).log"
echo "Strace output -> $OUTFILE"
echo "Waiting for virtqemud..."

for i in $(seq 1 120); do
    PID=$(pgrep -x virtqemud 2>/dev/null || true)
    [ -n "$PID" ] && break
    sleep 0.1
done

if [ -z "$PID" ]; then
    echo "ERROR: virtqemud never appeared"
    exit 1
fi
echo "Attaching strace to virtqemud PID=$PID"

# -f: follow forks (catches QEMU child too)
# -tt: timestamps with microseconds
# -y: show fd paths
# -e trace=openat,open,write,writev,ioctl,mmap,brk,mprotect: focus on things that can fail
# -e status=failed: only show FAILED syscalls
timeout 30 strace -f -tt -y -e status=failed -e trace=all -p "$PID" 2>&1 | tee "$OUTFILE" || true

echo ""
echo "=== FAILED SYSCALLS ==="
grep -v '^$' "$OUTFILE" | head -100
