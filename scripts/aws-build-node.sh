#!/usr/bin/env bash
# Start/stop/status for the AWS Graviton build node (infra/aws-graviton-build/).
# Stopped, not terminated -- the EBS root volume (toolchain, caches, joined
# k3s/Pelagos/Tailscale identity) persists; only compute cost stops accruing.
# See docs/aws-graviton-build-node.md.
#
# stop/start also manage a pair of *targeted* Alertmanager silences so
# KubeNodeNotReady/KubeDaemonSetNotFullyReady don't fire for a node that's
# intentionally stopped -- see silence_status_* below for exactly what's
# matched and the known scoping limitation.
#
# Usage: ./aws-build-node.sh <start|stop|status>
set -uo pipefail
# Deliberately not `set -e` at the top level -- same reasoning as
# scripts/cluster-scheduler/silence-alerts.sh: `var=$(fn)` doesn't reliably
# abort under `set -e` when fn fails, so every Alertmanager helper below
# returns (not exits) on failure and every caller checks explicitly.

PROFILE="administrator"
REGION="us-west-2"
INSTANCE_NAME="aws-graviton-build"
ALERTMANAGER="http://192.168.89.2:9093"
# Alertmanager is only LAN-reachable, and this script runs on whatever
# machine has AWS credentials -- not necessarily one with a route to the
# LAN (e.g. no Tailscale subnet-route is advertised anymore, by design,
# per k3s-experiments#20). Route through ipc4 via SSH so this works
# regardless of where it's invoked from.
LAN_JUMP="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 cb@ipc4.taildd208.ts.net"
SILENCE_CREATED_BY="aws-build-node.sh"
# Safety cap, not the expected lifetime -- start always deletes these
# immediately. This just bounds the damage if start is never called
# (e.g. the instance gets terminated and rebuilt some other way).
SILENCE_MAX_DURATION_H=24

instance_id() {
    aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
        --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text
}

# ── Alertmanager silence helpers ────────────────────────────────────────────
# Two separate silences, not one with two matchers -- a single silence's
# matchers are ANDed, and these are logically an OR (either alert should be
# suppressed). Both share createdBy so start can find and remove them as a
# pair without tracking IDs across the stop/start boundary.
#
# Scoping limitation: KubeDaemonSetNotFullyReady has no per-node label, only
# daemonset+namespace, so this silences cilium/cilium-envoy/node-exporter/
# spire-agent DaemonSet issues *cluster-wide* while the AWS node is stopped
# -- not just the AWS-node-caused instance of that alert. Acceptable given
# this is a short, on-demand window (not overnight), but a genuine DaemonSet
# problem on ipc4-9 during that window would also go quiet. Worth knowing.

am_post_silence() {
    local matchers_json="$1" comment="$2"
    local now ends_at payload result
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    ends_at=$(date -u -v+${SILENCE_MAX_DURATION_H}H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -d "+${SILENCE_MAX_DURATION_H} hours" +"%Y-%m-%dT%H:%M:%SZ")
    payload="{\"matchers\": $matchers_json, \"startsAt\": \"$now\", \"endsAt\": \"$ends_at\", \"createdBy\": \"$SILENCE_CREATED_BY\", \"comment\": \"$comment\"}"
    if ! result=$($LAN_JUMP "curl -sf --max-time 10 -X POST '$ALERTMANAGER/api/v2/silences' -H 'Content-Type: application/json' -d '$payload'"); then
        echo "WARNING: could not reach Alertmanager (via ipc4) to create silence ($comment)" >&2
        return 1
    fi
    echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['silenceID'])"
}

silence_on() {
    local node_id ds_id
    node_id=$(am_post_silence \
        '[{"name":"alertname","value":"KubeNodeNotReady","isRegex":false},{"name":"node","value":"'"$INSTANCE_NAME"'","isRegex":false}]' \
        "$INSTANCE_NAME intentionally stopped") \
        || { echo "  (KubeNodeNotReady silence failed -- continuing anyway)" >&2; }
    ds_id=$(am_post_silence \
        '[{"name":"alertname","value":"KubeDaemonSetNotFullyReady","isRegex":false},{"name":"daemonset","value":"^(cilium|cilium-envoy|node-exporter|spire-agent)$","isRegex":true}]' \
        "$INSTANCE_NAME intentionally stopped (DaemonSets scheduled on it)") \
        || { echo "  (KubeDaemonSetNotFullyReady silence failed -- continuing anyway)" >&2; }
    if [[ -n "${node_id:-}" || -n "${ds_id:-}" ]]; then
        echo "  Alerts silenced for up to ${SILENCE_MAX_DURATION_H}h (removed automatically on next 'start')."
    fi
}

silence_off() {
    local body ids
    if ! body=$($LAN_JUMP "curl -sf --max-time 10 '$ALERTMANAGER/api/v2/silences'"); then
        echo "  WARNING: could not reach Alertmanager (via ipc4) to remove silences -- they'll self-expire within ${SILENCE_MAX_DURATION_H}h" >&2
        return 0
    fi
    ids=$(echo "$body" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if s.get('createdBy') == '$SILENCE_CREATED_BY' and s['status']['state'] == 'active':
        print(s['id'])
")
    if [[ -z "$ids" ]]; then
        return 0
    fi
    while read -r id; do
        [[ -z "$id" ]] && continue
        # </dev/null on the ssh call is required here, not cosmetic: without
        # it, ssh's own stdin competes with this while-loop's `read` for the
        # here-string below, silently swallowing the second (and any later)
        # id after the first iteration -- classic `ssh` -inside-`while read`
        # bug. Confirmed the hard way: only 1 of 2 silences got removed
        # before this was added.
        if $LAN_JUMP "curl -sf --max-time 10 -X DELETE '$ALERTMANAGER/api/v2/silence/$id'" </dev/null >/dev/null; then
            echo "  Removed silence $id"
        else
            echo "  WARNING: failed to remove silence $id -- it'll self-expire within ${SILENCE_MAX_DURATION_H}h" >&2
        fi
    done <<< "$ids"
}

# ── main ─────────────────────────────────────────────────────────────────────

ID=$(instance_id)
if [[ -z "$ID" || "$ID" == "None" ]]; then
    echo "ERROR: no instance found tagged Name=$INSTANCE_NAME in $REGION" >&2
    exit 1
fi

case "${1:-status}" in
    start)
        echo "=== Starting $INSTANCE_NAME ($ID) ==="
        aws ec2 start-instances --profile "$PROFILE" --region "$REGION" --instance-ids "$ID" >/dev/null
        aws ec2 wait instance-running --profile "$PROFILE" --region "$REGION" --instance-ids "$ID"
        echo "Running. Tailscale/SSH may take another 10-20s to come up after boot."
        silence_off
        ;;
    stop)
        echo "=== Stopping $INSTANCE_NAME ($ID) ==="
        aws ec2 stop-instances --profile "$PROFILE" --region "$REGION" --instance-ids "$ID" >/dev/null
        aws ec2 wait instance-stopped --profile "$PROFILE" --region "$REGION" --instance-ids "$ID"
        echo "Stopped. Compute billing paused; EBS storage still accrues (~\$8/mo for 100GB gp3)."
        silence_on
        ;;
    status)
        aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" --instance-ids "$ID" \
            --query 'Reservations[0].Instances[0].[InstanceId,State.Name,InstanceType]' --output table
        ;;
    *)
        echo "Usage: $0 <start|stop|status>" >&2
        exit 1
        ;;
esac
