#!/bin/bash
# Controls PXE autoinstall for ipc nodes by enabling/disabling MAC boot files
# on the netboot.xyz TFTP server.
#
# Run from omen. Enabling a node causes it to autoinstall Ubuntu on next PXE boot.
# Disabling a node causes it to fall through to local disk on next PXE boot.
#
# Usage:
#   pxe-control.sh status
#   pxe-control.sh enable  <node>   # node: ipc1 | ipc2 | ipc3 | all
#   pxe-control.sh disable <node>
#
# Requires BIOS boot order: PXE first, local disk second.
set -euo pipefail

# If not running on nazgul, re-exec via SSH
if [ "$(hostname)" != "nazgul" ]; then
    exec ssh root@nazgul "bash ~/pxe-control.sh $*"
fi

MENUS=/mnt/.ix-apps/app_mounts/netbootxyz/config/menus

declare -A NODE_MAC=(
    [ipc1]="MAC-a8a159432a67.ipxe"
    [ipc2]="MAC-a8a159432aed.ipxe"
    [ipc3]="MAC-a8a159432a74.ipxe"
    [ipc4]="MAC-d0ad089cd2cb.ipxe"
    [ipc5]="MAC-d0ad089cd145.ipxe"
)

usage() {
    echo "Usage: $0 status"
    echo "       $0 enable  <ipc1|ipc2|ipc3|ipc4|ipc5|all>"
    echo "       $0 disable <ipc1|ipc2|ipc3|ipc4|ipc5|all>"
    exit 1
}

status() {
    echo "PXE autoinstall status:"
    for node in ipc1 ipc2 ipc3; do
        file="${MENUS}/${NODE_MAC[$node]}"
        if [ -f "$file" ]; then
            echo "  $node: ENABLED"
        else
            echo "  $node: disabled"
        fi
    done
}

enable_node() {
    local node=$1
    local file="${MENUS}/${NODE_MAC[$node]}"
    local disabled="${file}.disabled"
    if [ -f "$file" ]; then
        chown apps:apps "$file"
        echo "$node: already enabled (ownership fixed)"
    elif [ -f "$disabled" ]; then
        mv "$disabled" "$file"
        chown apps:apps "$file"
        echo "$node: enabled"
    else
        echo "$node: no file found (check repo deployment)" >&2
        exit 1
    fi
}

disable_node() {
    local node=$1
    local file="${MENUS}/${NODE_MAC[$node]}"
    if [ -f "$file" ]; then
        mv "$file" "${file}.disabled"
        echo "$node: disabled"
    else
        echo "$node: already disabled"
    fi
}

[ $# -lt 1 ] && usage

CMD=$1
NODE=${2:-}

case "$CMD" in
    status)
        status
        ;;
    enable|disable)
        [ -z "$NODE" ] && usage
        NODES=()
        if [ "$NODE" = "all" ]; then
            NODES=(ipc1 ipc2 ipc3 ipc4 ipc5)
        elif [ -n "${NODE_MAC[$NODE]+x}" ]; then
            NODES=("$NODE")
        else
            echo "Unknown node: $NODE" >&2
            usage
        fi
        for n in "${NODES[@]}"; do
            "${CMD}_node" "$n"
        done
        ;;
    *)
        usage
        ;;
esac
