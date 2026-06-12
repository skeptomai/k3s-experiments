#!/usr/bin/env bash
# Remove stale Tailscale device(s) for the given node(s) BEFORE a reinstall, so
# the freshly-installed node re-enrolls and cleanly claims its name (no <node>-1
# suffix). Also supports a post-install --verify check.
#
# Why before-enroll: Tailscale won't reassign a name that an existing (offline)
# device still owns, so a reinstalled node becomes <node>-1 and <node> resolves
# to the dead machine. The API has a clean device *delete* but no MagicDNS
# *rename*, so the only robust fix is to delete the old device first.
#
# Credentials — a Tailscale OAuth client with devices:core (write) scope, plus
# tagOwners for the nodes' tag. Provided via (first match wins):
#   1. env: TS_OAUTH_CLIENT_ID / TS_OAUTH_CLIENT_SECRET
#   2. 1Password: op read "$TS_OP_ITEM/client_id" and /client_secret
#      (TS_OP_ITEM defaults to "op://Private/Tailscale OAuth k3s")
# If neither is available, warns and exits 0 (non-fatal — manual console cleanup).
#
# Usage:
#   tailscale-cleanup.sh <node> [node...]            # delete stale devices
#   tailscale-cleanup.sh --verify <node> [node...]   # assert clean single device
set -uo pipefail

API="https://api.tailscale.com/api/v2"
TS_OP_ITEM="${TS_OP_ITEM:-op://Private/Tailscale OAuth k3s}"

load_creds() {
  [[ -n "${TS_OAUTH_CLIENT_ID:-}" && -n "${TS_OAUTH_CLIENT_SECRET:-}" ]] && return 0
  if command -v op >/dev/null 2>&1; then
    TS_OAUTH_CLIENT_ID=$(op read "${TS_OP_ITEM}/client_id" 2>/dev/null) || true
    TS_OAUTH_CLIENT_SECRET=$(op read "${TS_OP_ITEM}/client_secret" 2>/dev/null) || true
  fi
  [[ -n "${TS_OAUTH_CLIENT_ID:-}" && -n "${TS_OAUTH_CLIENT_SECRET:-}" ]]
}

get_token() {
  curl -s -X POST "$API/oauth/token" \
    -d "client_id=$TS_OAUTH_CLIENT_ID" \
    -d "client_secret=$TS_OAUTH_CLIENT_SECRET" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null
}

# Print "id<TAB>name<TAB>lastSeen" for every device whose OS hostname == $1.
# Matching by hostname catches both <node> and <node>-N variants.
devices_for_host() {
  local node=$1 json=$2
  echo "$json" | python3 -c "
import json,sys
node=sys.argv[1]
for dev in json.load(sys.stdin).get('devices',[]):
    if dev.get('hostname')==node:
        print(dev['id']+'\t'+dev.get('name','')+'\t'+dev.get('lastSeen',''))
" "$node"
}

VERIFY=0
[[ "${1:-}" == "--verify" ]] && { VERIFY=1; shift; }
[[ $# -ge 1 ]] || { echo "Usage: $0 [--verify] <node> [node...]"; exit 1; }

if ! load_creds; then
  echo "WARN: no Tailscale OAuth creds (env or $TS_OP_ITEM) — skipping device cleanup."
  echo "      Remove stale <node>/<node>-1 devices manually in the admin console."
  exit 0
fi

TOKEN=$(get_token)
[[ -n "$TOKEN" ]] || { echo "WARN: could not obtain Tailscale API token — skipping."; exit 0; }

DEVICES=$(curl -s -H "Authorization: Bearer $TOKEN" "$API/tailnet/-/devices")

rc=0
for node in "$@"; do
  if [[ $VERIFY -eq 1 ]]; then
    mapfile -t rows < <(devices_for_host "$node" "$DEVICES")
    if [[ ${#rows[@]} -eq 1 && "${rows[0]#*$'\t'}" == "${node}."* ]]; then
      echo "  OK: $node -> single device ${rows[0]%%$'\t'*} (name ${rows[0]#*$'\t'})"
    else
      echo "  WARN: $node has ${#rows[@]} device(s); expected exactly one named '${node}.<tailnet>'."
      printf '        %s\n' "${rows[@]}"
      rc=1
    fi
    continue
  fi

  echo "--- Tailscale: removing stale devices with hostname '$node' ---"
  local_found=0
  while IFS=$'\t' read -r id name seen; do
    [[ -z "$id" ]] && continue
    local_found=1
    code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: Bearer $TOKEN" "$API/device/$id")
    if [[ "$code" == "200" ]]; then
      echo "  removed $name ($id, last seen ${seen:-?})"
    else
      echo "  WARN: delete failed for $name ($id) — HTTP $code"; rc=1
    fi
  done < <(devices_for_host "$node" "$DEVICES")
  [[ $local_found -eq 0 ]] && echo "  (no existing device for $node)"
done

exit $rc
