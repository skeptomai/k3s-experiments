#!/bin/bash
# Attach strace to virtqemud, follow all forks, capture the pre-exec child's syscalls.
# Focused on: exec, fd manipulation, writes to errpipe, exits.
# Run on ipc8 BEFORE applying the VMI. Script auto-kills after 8s.
set -euo pipefail

LOGFILE="/tmp/strace-preexec-$(date +%s).log"
echo "Waiting for virtqemud... log -> $LOGFILE"

PID=""
for i in $(seq 1 60); do
    PID=$(pgrep -x virtqemud 2>/dev/null | head -1 || true)
    if [ -n "$PID" ]; then
        echo "Found virtqemud PID=$PID, attaching strace..."
        break
    fi
    sleep 0.2
done

if [ -z "$PID" ]; then
    echo "ERROR: virtqemud not found after 12s"
    exit 1
fi

# -f: follow all forks/clones (catches pre-exec child)
# -tt: microsecond timestamps
# -y: show fd paths where known
# Focused syscall set: process lifecycle + fd ops + writes + capabilities
strace -f -tt -y \
    -e trace=execve,execveat,clone,fork,vfork,exit_group,\
dup2,dup3,close,openat,fcntl,\
write,read,\
capset,prctl,setuid,setgid,setresuid,setresgid \
    -p "$PID" -o "$LOGFILE" &
STRACE_PID=$!

echo "strace running (PID=$STRACE_PID), will auto-kill in 8s"
sleep 8
kill "$STRACE_PID" 2>/dev/null || true
wait "$STRACE_PID" 2>/dev/null || true

echo "Done. Lines: $(wc -l < "$LOGFILE")"
echo "Log: $LOGFILE"
echo ""
echo "=== exit_group events ==="
grep "exit_group" "$LOGFILE" || echo "(none)"
echo ""
echo "=== execve events ==="
grep "execve" "$LOGFILE" || echo "(none)"
echo ""
echo "=== write to fd=4 (errpipe) ==="
grep 'write(4,' "$LOGFILE" || echo "(none)"
echo ""
echo "=== capset/setuid failures ==="
grep -E "capset|setuid|setgid|setresuid" "$LOGFILE" | grep -v " = 0$" || echo "(none)"
