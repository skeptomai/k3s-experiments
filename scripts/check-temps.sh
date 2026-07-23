#!/usr/bin/env bash
# Check CPU and NVMe temperatures across all cluster nodes and nazgul.
# Usage: bash scripts/check-temps.sh

SSH="ssh -o ControlMaster=no -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o BatchMode=yes"

# Prefer LAN (no tailnet variance); fall back to tailnet when off-LAN.
if timeout 1 bash -c 'echo >/dev/tcp/192.168.88.55/22' 2>/dev/null; then
    IPC4=192.168.88.55
else
    IPC4=ipc4.taildd208.ts.net
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# One SSH to ipc4; collect local sensors there + LAN-SSH to ipc5-9 from ipc4.
# This avoids 6 parallel jump-host connections hammering sshd's MaxStartups limit.
$SSH cb@"$IPC4" 'bash -s' >"$WORKDIR/cluster" 2>/dev/null << 'ENDSSH'
INNER="ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10"

sensors -u 2>/dev/null | \
  awk '/coretemp/{c=1} c&&/temp1_input/{pkg=$2;c=0} /nvme/{n=1} n&&/temp1_input/{nv=$2;n=0} END{printf "ipc4 %.0f %.0f\n",pkg,nv}' &

for entry in "ipc5:192.168.88.56" "ipc6:192.168.88.57" \
             "ipc7:192.168.88.63" "ipc8:192.168.88.64" "ipc9:192.168.88.65"; do
  node=${entry%%:*}; ip=${entry##*:}
  $INNER cb@$ip \
    "sensors -u 2>/dev/null | awk -v nn=$node '/coretemp/{c=1} c&&/temp1_input/{pkg=\$2;c=0} /nvme/{nf=1} nf&&/temp1_input/{nv=\$2;nf=0} END{printf nn\" %.0f %.0f\n\",pkg,nv}'" \
    2>/dev/null &
done
wait
ENDSSH

# Nazgul: direct connection, runs in parallel with the ipc4 block above
$SSH root@nazgul.taildd208.ts.net \
  "sensors -u 2>/dev/null | awk '/k10temp/{k=1} k&&/temp1_input/{cpu=\$2;k=0} /^nvme/{n=1} n&&/temp1_input/{nv=\$2;n=0} /drivetemp/{d=1} d&&/temp1_input/{s+=\$2;c++;d=0} END{printf \"nazgul %.0f %.0f %.0f\n\",cpu,nv,s/c}'" \
  >"$WORKDIR/nazgul" 2>/dev/null &

wait

declare -A ROLE=([ipc4]="cp+etcd" [ipc5]="cp+etcd" [ipc6]="cp+etcd"
                 [ipc7]="worker"  [ipc8]="worker"  [ipc9]="worker")

print_row() {
    printf "| %-6s | %-7s | %3d°C    | %3d°C  | %-13s |\n" "$1" "$2" "$3" "$4" "$5"
}

echo "+--------+---------+----------+--------+---------------+"
echo "| Node   | Role    | CPU pkg  | NVMe   | Other         |"
echo "+--------+---------+----------+--------+---------------+"

WARN=""
for node in ipc4 ipc5 ipc6 ipc7 ipc8 ipc9; do
    line=$(grep "^$node " "$WORKDIR/cluster" 2>/dev/null)
    if [ -n "$line" ]; then
        read -r _ cpu nv <<< "$line"
        print_row "$node" "${ROLE[$node]}" "$cpu" "$nv" ""
        [ "$cpu" -ge 70 ] 2>/dev/null && WARN="${WARN}WARN: $node CPU ${cpu}°C >= 70°C\n"
        [ "$nv"  -ge 70 ] 2>/dev/null && WARN="${WARN}WARN: $node NVMe ${nv}°C >= 70°C\n"
    else
        printf "| %-6s | %-7s | %-8s | %-6s | %-13s |\n" "$node" "${ROLE[$node]}" "no data" "no data" ""
        WARN="${WARN}WARN: no data received from $node\n"
    fi
done

read -r _ cpu nv hdds <"$WORKDIR/nazgul" 2>/dev/null || { cpu=0; nv=0; hdds=0; }
print_row "nazgul" "infra" "$cpu" "$nv" "HDDs avg ${hdds}°C"
[ "$hdds" -ge 50 ] 2>/dev/null && WARN="${WARN}WARN: nazgul HDDs avg ${hdds}°C >= 50°C\n"

echo "+--------+---------+----------+--------+---------------+"
if [ -n "$WARN" ]; then
    printf "\n$WARN"
else
    echo "All temps normal."
fi
