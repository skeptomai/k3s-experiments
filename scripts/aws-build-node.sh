#!/usr/bin/env bash
# Start/stop/status for the AWS Graviton build node (infra/aws-graviton-build/).
# Stopped, not terminated -- the EBS root volume (toolchain, caches, joined
# k3s/Pelagos/Tailscale identity) persists; only compute cost stops accruing.
# See docs/aws-graviton-build-node.md.
#
# 2026-09-30: stop/start now delete/recreate the k8s Node object instead of
# leaving it behind as NotReady. History here: originally `stop` left the
# Node object in place and silenced KubeNodeNotReady (scoped to
# node=aws-graviton-build) plus KubeDaemonSetNotFullyReady for
# cilium/cilium-envoy/node-exporter/spire-agent. That DaemonSet silence had
# no per-node label to scope it, so it was cluster-wide, not
# AWS-node-specific -- and on 2026-09-29 that was found to have silently
# masked a real, unrelated Pelagos CRI bug on ipc7 for the 41 days the node
# sat stopped. The fix that day removed the DaemonSet silence outright and
# accepted the resulting noise (over-alert, not under-alert) since
# Prometheus has no clean way to express "this daemonset alert, but only
# when the missing pod is specifically on aws-graviton-build" from
# kube_daemonset_status_* alone -- that metric has no per-node label.
#
# But the noise wasn't actually necessary: kube_daemonset_status_desired_
# number_scheduled counts any Node object matching the DaemonSet's
# selector, NotReady or not (confirmed: cilium/cilium-envoy only require
# os=linux, node-exporter/spire-agent have no selector at all -- none
# restrict by hostname). So a stopped-but-still-registered Node is exactly
# what inflates "desired" past "ready" and fires both alerts. Deleting the
# Node object when stopped (no PVs are bound here, confirmed safe) drops
# it out of "desired" too, so neither alert fires -- correctly, because the
# state is now accurate, not because anything is suppressed. The k3s agent
# recreates its own Node object automatically on boot (it reuses the
# identity already persisted on the EBS volume), so `start` needs no
# manual re-registration, just a wait for Ready. No Alertmanager silence
# of any kind is needed any more; this replaces that mechanism entirely.
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
# regardless of where it's invoked from. Only used now for clearing out any
# pre-2026-09-30 silences left over from the old mechanism (see header).
LAN_JUMP="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 cb@ipc4.taildd208.ts.net"
SILENCE_CREATED_BY="aws-build-node.sh"

instance_id() {
    aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
        --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text
}

# ── k8s Node lifecycle ──────────────────────────────────────────────────────
# Plain kubectl, not SSH-wrapped: unlike Alertmanager, ipc4:6443 is
# tailnet-reachable directly (same as every other script in this repo that
# runs from omen), so no LAN jump is needed here.
node_delete() {
    if ! kubectl delete node "$INSTANCE_NAME" --ignore-not-found --timeout=15s >/dev/null 2>&1; then
        echo "  WARNING: could not delete Node object $INSTANCE_NAME (kubectl unreachable, or delete failed) -- KubeNodeNotReady/KubeDaemonSetNotFullyReady may fire until this is cleaned up (rerun '$0 stop', or 'kubectl delete node $INSTANCE_NAME' manually)" >&2
        return 1
    fi
    echo "  Deleted Node object $INSTANCE_NAME (k3s agent recreates it automatically on next 'start')."
}

node_wait_ready() {
    echo "  Waiting for Node object $INSTANCE_NAME to re-register and go Ready..."
    if kubectl wait "node/$INSTANCE_NAME" --for=condition=Ready --timeout=120s >/dev/null 2>&1; then
        echo "  Node Ready."
    else
        echo "  WARNING: Node $INSTANCE_NAME did not reach Ready within 120s -- check 'kubectl get node $INSTANCE_NAME' and k3s-agent on the instance" >&2
    fi
}

# ── legacy silence cleanup ──────────────────────────────────────────────────
# One-time-ish migration helper: clears any still-active silence created by
# the pre-2026-09-30 mechanism (far-future endsAt, so these don't self-expire
# on their own). Safe to call unconditionally -- a no-op once none are left.
clear_legacy_silences() {
    local body ids
    if ! body=$($LAN_JUMP "curl -sf --max-time 10 '$ALERTMANAGER/api/v2/silences'" 2>/dev/null); then
        return 0
    fi
    ids=$(echo "$body" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if s.get('createdBy') == '$SILENCE_CREATED_BY' and s['status']['state'] == 'active':
        print(s['id'])
" 2>/dev/null)
    if [[ -z "$ids" ]]; then
        return 0
    fi
    while read -r id; do
        [[ -z "$id" ]] && continue
        # </dev/null required -- ssh's own stdin otherwise competes with this
        # while-loop's `read` for the here-string, silently swallowing every
        # id after the first iteration. Confirmed the hard way previously.
        if $LAN_JUMP "curl -sf --max-time 10 -X DELETE '$ALERTMANAGER/api/v2/silence/$id'" </dev/null >/dev/null; then
            echo "  Cleared legacy silence $id"
        else
            echo "  WARNING: failed to clear legacy silence $id" >&2
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
        node_wait_ready
        clear_legacy_silences
        ;;
    stop)
        echo "=== Stopping $INSTANCE_NAME ($ID) ==="
        aws ec2 stop-instances --profile "$PROFILE" --region "$REGION" --instance-ids "$ID" >/dev/null
        aws ec2 wait instance-stopped --profile "$PROFILE" --region "$REGION" --instance-ids "$ID"
        echo "Stopped. Compute billing paused; EBS storage still accrues (~\$8/mo for 100GB gp3)."
        node_delete
        ;;
    status)
        STATE=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" --instance-ids "$ID" \
            --query 'Reservations[0].Instances[0].State.Name' --output text)
        aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" --instance-ids "$ID" \
            --query 'Reservations[0].Instances[0].[InstanceId,State.Name,InstanceType]' --output table

        # Drift check: does Node registration actually match instance state?
        # This is the real safety net -- catches the instance being
        # stopped/started outside this script, or a delete that failed
        # partway through.
        NODE_EXISTS=$(kubectl get node "$INSTANCE_NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ -z "$NODE_EXISTS" ]]; then
            echo "  (could not check Node registration -- kubectl unreachable)"
        elif [[ "$STATE" == "stopped" && "$NODE_EXISTS" != "0" ]]; then
            echo "  DRIFT: instance is stopped but Node object still exists -- KubeNodeNotReady/KubeDaemonSetNotFullyReady may be firing. Run '$0 stop' again to clean up."
        elif [[ "$STATE" == "running" && "$NODE_EXISTS" == "0" ]]; then
            echo "  DRIFT: instance is running but no Node object exists -- k3s-agent may not have rejoined yet, or something's wrong. Check 'journalctl -u k3s-agent' on the instance, or rerun '$0 start'."
        else
            echo "  Node registration state consistent with instance state."
        fi
        clear_legacy_silences
        ;;
    unsilence)
        # Pure migration/cleanup: clears any leftover silence from the old
        # mechanism WITHOUT touching instance or Node state.
        echo "=== Clearing legacy silences for $INSTANCE_NAME ==="
        clear_legacy_silences
        ;;
    *)
        echo "Usage: $0 <start|stop|status|unsilence>" >&2
        exit 1
        ;;
esac
