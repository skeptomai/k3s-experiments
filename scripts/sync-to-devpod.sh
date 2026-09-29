#!/usr/bin/env bash
# Local-edit / remote-build sync: rsyncs a local working tree to the
# personal dev pod (docs/personal-dev-pod.md) without needing a git commit
# per intermediate state. Meant for the routine edit/build/test loop; use
# plain `git push`/`pull` for deliberate snapshots.
#
# Usage: scripts/sync-to-devpod.sh <local-dir> [remote-subdir]
#   local-dir:    path to sync (e.g. ~/Projects/some-project)
#   remote-subdir: destination under the pod's home dir, ~/<remote-subdir>/
#                  (default: basename of local-dir)
#
# Excludes target/, .git/, and node_modules/ by default -- these are
# either rebuilt remotely or better handled by a real git push/pull.
set -euo pipefail

DEVPOD_HOST="cb@devbox.taildd208.ts.net"
SSH_KEY="$HOME/.ssh/Omen"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <local-dir> [remote-subdir]" >&2
  exit 1
fi

LOCAL_DIR="$1"
[[ -d "$LOCAL_DIR" ]] || { echo "ERROR: not a directory: $LOCAL_DIR" >&2; exit 1; }
LOCAL_DIR="${LOCAL_DIR%/}/"

REMOTE_SUBDIR="${2:-$(basename "${LOCAL_DIR%/}")}"

echo "==> syncing $LOCAL_DIR -> ${DEVPOD_HOST}:~/${REMOTE_SUBDIR}/"
rsync -avz --delete \
  --exclude '.git/' \
  --exclude 'target/' \
  --exclude 'node_modules/' \
  -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new" \
  "$LOCAL_DIR" "${DEVPOD_HOST}:~/${REMOTE_SUBDIR}/"
echo "==> done"
