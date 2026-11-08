#!/bin/bash
# Pull an object out of AIStor (reassembling multipart parts via mc) and place it
# into a Plex library folder with correct ownership/permissions.
#
# Run on nazgul (as root): bash aistor-retrieve-to-plex.sh <bucket> <object-key> <movie-folder-name> <dest-filename>
# Example:                 bash aistor-retrieve-to-plex.sh uploads-external M_A_S_H.m4v MASH MASH.m4v
#
# Why mc and not a raw file copy: AIStor stores a multipart-uploaded object as
# separate part.N files plus an xl.meta recipe (see services.md's AIStor section) --
# concatenating those by hand risks corruption. `mc cp` goes through the real S3 API,
# which is the only thing that correctly reassembles them into one file.
#
# No password prompt needed: MINIO_ROOT_USER/MINIO_ROOT_PASSWORD are already set as
# env vars inside the ix-aistor-aistor-1 container (see services.md) -- read those
# directly instead of asking interactively, which also sidesteps the PTY/hanging
# issue hit the first time this was scripted (ssh without -t doesn't allocate a tty,
# so an interactive `read` prompt can hang or garble input).

set -euo pipefail

BUCKET="${1:?usage: $0 <bucket> <object-key> <movie-folder-name> <dest-filename>}"
OBJECT_KEY="${2:?}"
MOVIE_FOLDER="${3:?}"
DEST_FILENAME="${4:?}"

CONTAINER="ix-aistor-aistor-1"
DEST_DIR="/mnt/primary_storage/Plex/Movies/${MOVIE_FOLDER}"
TMP_IN_CONTAINER="/tmp/$(basename "$OBJECT_KEY")"

echo "==> Setting mc alias from the container's own root env vars..."
docker exec "$CONTAINER" sh -c 'mc alias set local http://localhost:30320 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"'

echo "==> Verifying credentials actually work (listing buckets)..."
if ! docker exec "$CONTAINER" mc ls local >/dev/null 2>&1; then
  echo "!!! mc ls local failed -- MINIO_ROOT_USER/PASSWORD env vars may be missing or stale in this container. Aborting before touching anything else." >&2
  exit 1
fi

echo "==> Verifying the object exists and is readable..."
if ! docker exec "$CONTAINER" mc stat "local/${BUCKET}/${OBJECT_KEY}" >/dev/null 2>&1; then
  echo "!!! mc stat failed for local/${BUCKET}/${OBJECT_KEY} -- check the bucket/object-key arguments." >&2
  exit 1
fi

echo "==> Pulling object out (mc reassembles multipart parts into one file)..."
docker exec "$CONTAINER" mc cp "local/${BUCKET}/${OBJECT_KEY}" "$TMP_IN_CONTAINER"

echo "==> Copying out of the container onto the host..."
mkdir -p "$DEST_DIR"
docker cp "${CONTAINER}:${TMP_IN_CONTAINER}" "${DEST_DIR}/${DEST_FILENAME}"

echo "==> Fixing ownership/permissions to match the Plex library..."
chown apps:apps "$DEST_DIR" "${DEST_DIR}/${DEST_FILENAME}"
chmod 775 "$DEST_DIR" "${DEST_DIR}/${DEST_FILENAME}"

echo "==> Cleaning up temp copy inside the container..."
docker exec "$CONTAINER" rm "$TMP_IN_CONTAINER"

echo "==> Done: ${DEST_DIR}/${DEST_FILENAME}"
ls -la "$DEST_DIR"
