#!/usr/bin/env bash
# Build the ipvs-demo image on ipc7 using pelagos, push to local registry.
# Run from omen: bash experiments/31-ipvs-demo/build.sh
set -euo pipefail

JUMP="cb@ipc4.taildd208.ts.net"
BUILD_NODE="ipc7"
IMAGE="192.168.89.2:5004/ipvs-demo:latest"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/server" && pwd)"

echo "==> copying source to $BUILD_NODE"
ssh -o BatchMode=yes -J "$JUMP" "cb@$BUILD_NODE" "rm -rf /tmp/ipvs-demo-src && mkdir /tmp/ipvs-demo-src"
ssh -o BatchMode=yes -J "$JUMP" "cb@$BUILD_NODE" "cat > /tmp/ipvs-demo-src/main.go" < "$SRC/main.go"
ssh -o BatchMode=yes -J "$JUMP" "cb@$BUILD_NODE" "cat > /tmp/ipvs-demo-src/Remfile"  < "$SRC/Remfile"

echo "==> pelagos build on $BUILD_NODE"
ssh -o BatchMode=yes -J "$JUMP" "cb@$BUILD_NODE" "sudo pelagos build --tag $IMAGE /tmp/ipvs-demo-src"

echo "==> pushing $IMAGE"
ssh -o BatchMode=yes -J "$JUMP" "cb@$BUILD_NODE" "sudo pelagos image push --insecure $IMAGE"

echo "==> done: $IMAGE"
