#!/bin/bash
# Attach strace to virtqemud the moment it appears, capturing any failed syscalls.
# Run this on the node where the VMI will be scheduled BEFORE applying the VMI.
# Usage: bash strace-virtqemud.sh

set -euo pipefail

LOGFILE="/tmp/virtqemud-strace-$(date +%s).log"
echo "Waiting for virtqemud... strace output -> $LOGFILE"

# Wait until virtqemud appears
for i in $(seq 1 60); do
    PID=$(pgrep -x virtqemud 2>/dev/null || true)
    if [ -n "$PID" ]; then
        echo "Found virtqemud PID=$PID, attaching strace..."
        break
    fi
    sleep 0.2
done

if [ -z "$PID" ]; then
    echo "ERROR: virtqemud never appeared after 12 seconds"
    exit 1
fi

# Strace: capture all syscalls, follow forks, print timestamps.
# -e trace=all to get everything — we'll grep for cgroup later.
# -f to follow forks (virtqemud forks QEMU helper processes).
strace -f -tt -e trace=all -p "$PID" 2>&1 | tee "$LOGFILE" &
STRACE_PID=$!

# Wait for virtqemud to die (it dies within ~1s of starting QEMU)
wait "$STRACE_PID" 2>/dev/null || true

echo "Done. Log at $LOGFILE"
grep -i "cgroup\|EROFS\|EACCES\|EPERM\|kvm\|ENOENT" "$LOGFILE" | head -50 || echo "(no cgroup/permission lines found)"
