#!/usr/bin/env bash
# Run on ipc7 as root after the VMI completes to stop the HTTP server.
set -euo pipefail

if [ -f /tmp/http-server.pid ]; then
    PID=$(cat /tmp/http-server.pid)
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        echo "HTTP server (PID $PID) stopped"
    else
        echo "HTTP server already stopped"
    fi
    rm -f /tmp/http-server.pid
else
    echo "No PID file found"
fi
