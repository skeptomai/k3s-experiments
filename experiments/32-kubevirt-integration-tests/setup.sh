#!/usr/bin/env bash
# Run on ipc7 as root (via SSH from omen) before applying the VMI.
# Prepares the HTTP file server that the VM downloads test artifacts from.
set -euo pipefail

CACHE=/srv/pelagos-build/cache
PORT=9080

echo "==> creating integration_tests symlink"
TESTBIN=$(ls "$CACHE/target/release/deps/integration_tests-"* 2>/dev/null | grep -v '\.d$' | tail -1)
[ -n "$TESTBIN" ] || { echo "ERROR: no integration_tests binary — run the build job first" >&2; exit 1; }
ln -sfn "$TESTBIN" "$CACHE/target/release/deps/integration_tests"
echo "    -> $(basename "$TESTBIN")"

echo "==> creating repo-src.tar.gz (source tree, no .git or target/)"
tar -czf "$CACHE/repo-src.tar.gz" \
    -C "$CACHE/repo" \
    --exclude='.git' \
    --exclude='target' \
    --exclude='alpine-rootfs' \
    .
echo "    -> $(du -sh "$CACHE/repo-src.tar.gz" | cut -f1)"

echo "==> creating alpine-rootfs.tar.gz"
tar -czf "$CACHE/alpine-rootfs.tar.gz" \
    -C "$CACHE/repo" \
    alpine-rootfs/
echo "    -> $(du -sh "$CACHE/alpine-rootfs.tar.gz" | cut -f1)"

echo "==> starting HTTP server on port $PORT"
if [ -f /tmp/http-server.pid ] && kill -0 "$(cat /tmp/http-server.pid)" 2>/dev/null; then
    echo "    -> already running (PID $(cat /tmp/http-server.pid))"
else
    nohup python3 -m http.server "$PORT" --directory "$CACHE" \
        > /tmp/http-server.log 2>&1 &
    echo $! > /tmp/http-server.pid
    echo "    -> started PID $! (log: /tmp/http-server.log)"
fi

echo "==> ready — apply the VMI from omen:"
echo "    kubectl apply -f experiments/32-kubevirt-integration-tests/vmi.yaml"
