#!/usr/bin/env bash
# Run Pelagos integration tests directly on ipc7 (not inside a container).
# For manual use: ssh to ipc7 and run as root, or call via:
#   ssh -J cb@ipc4... cb@ipc7 "sudo bash" < scripts/run-integration-tests.sh
# The build job inlines an equivalent script via SSH stdin (no file path dependency).
set -euo pipefail

CACHE=/srv/pelagos-build/cache
REPO=$CACHE/repo
TARGET=$CACHE/target

# The test binary was compiled inside the pod with CARGO_TARGET_DIR=/cache/target.
# env!("CARGO_BIN_EXE_pelagos") is baked in as /cache/target/release/pelagos.
# Symlink /cache -> /srv/pelagos-build/cache so that path resolves on the host.
ln -sfn "$CACHE" /cache

# get_test_rootfs() looks for $current_dir/alpine-rootfs/bin/busybox.
ln -sfn /srv/pelagos-build/alpine-rootfs "$REPO/alpine-rootfs"

# Find the integration test binary compiled by the build pod (hash changes per build).
TESTBIN=$(ls "$TARGET/release/deps/integration_tests-"* 2>/dev/null | grep -v '\.d$' | tail -1)
if [ -z "$TESTBIN" ]; then
    echo "ERROR: no integration_tests binary in $TARGET/release/deps/" >&2
    exit 1
fi

echo "==> $(basename "$TESTBIN") on $(hostname) (direct, no pod wrapper)"
export PATH=/srv/pelagos-build/out:$PATH
cd "$REPO"
exec "$TESTBIN" --test-threads=1
