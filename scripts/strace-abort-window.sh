#!/bin/bash
# Broad-filter strace to capture everything in the 57µs window between
# the intel_cqm ENOENT and the proceed-pipe close.
# Adds stat, socket, connect, sendmsg, recvmsg, ioctl, access, getdents
# so we can see every syscall between the two events.
# Run on ipc8 BEFORE applying the VMI.
set -euo pipefail

LOGFILE="/tmp/strace-abort-$(date +%s).log"
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

# -f: follow all forks/clones
# -tt: microsecond timestamps
# -y: show fd paths where known
# -s 256: show first 256 bytes of string args (to capture domain XML snippets)
# Broad syscall set: adds stat, socket, connect, access on top of the original filter
strace -f -tt -y -s 256 \
    -e trace=execve,execveat,clone,fork,vfork,exit_group,\
dup2,dup3,close,openat,fcntl,\
write,read,\
capset,prctl,setuid,setgid,setresuid,setresgid,\
stat,fstat,lstat,newfstatat,statx,\
socket,connect,accept4,sendmsg,recvmsg,\
access,faccessat,\
ioctl \
    -p "$PID" -o "$LOGFILE" &
STRACE_PID=$!

echo "strace running (PID=$STRACE_PID), will auto-kill in 10s"
sleep 10
kill "$STRACE_PID" 2>/dev/null || true
wait "$STRACE_PID" 2>/dev/null || true

echo "Done. Lines: $(wc -l < "$LOGFILE")"
echo "Log: $LOGFILE"
echo ""
echo "=== intel_cqm and proceed-pipe close ==="
grep -n "intel_cqm\|17323" "$LOGFILE" | head -20
echo ""
echo "=== exit_group events ==="
grep "exit_group" "$LOGFILE" | head -10
echo ""
echo "=== execve events ==="
grep "execve" "$LOGFILE" | head -10
