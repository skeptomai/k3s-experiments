#!/usr/bin/env bash
# Single source of truth for ipc node data (IP / NIC / PXE MAC).
# Sourced by reinstall-nodes.sh, pxe-preflight.sh, and (indirectly) pxe-control.sh.
# Keeping these in ONE place avoids the drift that once left pxe-control.sh
# hardcoded to ipc1-6 while everything else knew ipc7-9.

declare -A NODE_IP=(
  [ipc1]="192.168.88.53" [ipc2]="192.168.88.52" [ipc3]="192.168.88.54"
  [ipc4]="192.168.88.55" [ipc5]="192.168.88.56" [ipc6]="192.168.88.57"
  [ipc7]="192.168.88.63" [ipc8]="192.168.88.64" [ipc9]="192.168.88.65"
)
declare -A NODE_NIC=(
  [ipc1]="enp2s0" [ipc2]="enp2s0" [ipc3]="enp2s0"
  [ipc4]="eno1" [ipc5]="eno1" [ipc6]="eno1"
  [ipc7]="eno1" [ipc8]="eno1" [ipc9]="eno1"
)
declare -A NODE_MAC=(
  [ipc1]="A8:A1:59:43:2A:67" [ipc2]="A8:A1:59:43:2A:ED" [ipc3]="A8:A1:59:43:2A:74"
  [ipc4]="D0:AD:08:9C:D2:CB" [ipc5]="D0:AD:08:9C:D1:45" [ipc6]="E0:73:E7:C0:B0:08"
  [ipc7]="E0:73:E7:3A:A6:7B" [ipc8]="7C:4D:8F:AA:FA:A4" [ipc9]="7C:4D:8F:AA:EF:73"
)

# Reinstallable worker nodes (ipc1 excluded — control-plane, needs the manual runbook).
REINSTALLABLE=(ipc2 ipc3 ipc4 ipc5 ipc6 ipc7 ipc8 ipc9)

mac_nocolon() { echo "${NODE_MAC[$1]}" | tr -d ':' | tr 'A-Z' 'a-z'; }
mac_dashed()  { echo "${NODE_MAC[$1]}" | tr ':' '-' | tr 'A-Z' 'a-z'; }
