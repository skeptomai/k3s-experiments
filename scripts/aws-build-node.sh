#!/usr/bin/env bash
# Start/stop/status for the AWS Graviton build node (infra/aws-graviton-build/).
# Stopped, not terminated -- the EBS root volume (toolchain, caches, joined
# k3s/Pelagos/Tailscale identity) persists; only compute cost stops accruing.
# See docs/aws-graviton-build-node.md.
#
# Usage: ./aws-build-node.sh <start|stop|status>
set -euo pipefail

PROFILE="administrator"
REGION="us-west-2"
INSTANCE_NAME="aws-graviton-build"

instance_id() {
    aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
        --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text
}

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
        ;;
    stop)
        echo "=== Stopping $INSTANCE_NAME ($ID) ==="
        aws ec2 stop-instances --profile "$PROFILE" --region "$REGION" --instance-ids "$ID" >/dev/null
        aws ec2 wait instance-stopped --profile "$PROFILE" --region "$REGION" --instance-ids "$ID"
        echo "Stopped. Compute billing paused; EBS storage still accrues (~\$8/mo for 100GB gp3)."
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
