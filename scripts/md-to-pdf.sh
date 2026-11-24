#!/usr/bin/env bash
# Forwarder. This script moved to https://github.com/skeptomai/markdown-to-gdoc
# (scripts/pdf/md-to-pdf.sh). Kept so existing callers keep working; edit the repo, not this file.
# Override the clone location with MD_TO_GDOC_DIR.
REPO="${MD_TO_GDOC_DIR:-$HOME/Projects/markdown-to-gdoc}"
TARGET="$REPO/scripts/pdf/md-to-pdf.sh"
if [[ ! -x "$TARGET" ]]; then
    echo "Error: $TARGET not found. Clone it: git clone https://github.com/skeptomai/markdown-to-gdoc.git $REPO" >&2
    exit 1
fi
exec "$TARGET" "$@"
