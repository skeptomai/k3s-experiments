#!/usr/bin/env bash
# Install and configure NUT server on ipc4 (USB-connected CyberPower LX1500GU3).
# ipc4 is the NUT master: it drives the USB HID driver, runs upsd, and monitors
# as master. All other ipc nodes are NUT clients (see install-nut-clients.sh).
# Run from omen after ipc4 reinstall, before install-nut-clients.sh.
#
# Hardware: CyberPower LX1500GU3, USB VID:PID 0764:0601, /dev/hidraw0 on ipc4.
# usbhid-ups accesses the device via libusb (/dev/bus/usb) — the udev rule grants
# the nut group access to both the USB bus node and the hidraw node.
set -euo pipefail

IPC4="cb@ipc4.taildd208.ts.net"
SSH="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

echo "Configuring NUT server on ipc4..."
ssh $SSH "$IPC4" "sudo bash -s" << 'ENDSSH'
set -euo pipefail

apt-get install -y nut -q

cat > /etc/nut/nut.conf << 'EOF'
MODE=netserver
EOF

cat > /etc/nut/ups.conf << 'EOF'
[cyberpower]
  driver = usbhid-ups
  port = auto
  vendorid = 0764
  productid = 0601
  desc = "CyberPower LX1500GU3"
EOF

cat > /etc/nut/upsd.conf << 'EOF'
LISTEN 127.0.0.1 3493
LISTEN 192.168.88.55 3493
EOF

cat > /etc/nut/upsd.users << 'EOF'
[upsmon]
  password = upsmon123
  upsmon master
EOF
chown root:nut /etc/nut/upsd.users
chmod 640 /etc/nut/upsd.users

cat > /etc/nut/upsmon.conf << 'EOF'
MONITOR cyberpower@localhost 1 upsmon upsmon123 master
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POLLFREQ 5
POLLFREQALERT 5
DEADTIME 60
POWERDOWNFLAG /etc/killpower
NOCOMMWARNTIME 300
FINALDELAY 5

NOTIFYCMD /usr/sbin/upssched
NOTIFYFLAG ONBATT SYSLOG+WALL+EXEC
NOTIFYFLAG ONLINE SYSLOG+WALL+EXEC
EOF

# upssched: 5-minute on-battery timer → FSD to all nodes
cat > /etc/nut/upssched.conf << 'EOF'
CMDSCRIPT /etc/nut/upssched-cmd
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock

AT ONBATT * START-TIMER onbatt 300
AT ONLINE * CANCEL-TIMER onbatt
EOF

cat > /etc/nut/upssched-cmd << 'EOF'
#!/bin/sh
case "$1" in
    onbatt)
        logger -t upssched "UPS on battery for 5 minutes — initiating cluster shutdown via FSD"
        /usr/sbin/upsmon -c fsd
        ;;
esac
EOF
chmod 755 /etc/nut/upssched-cmd
chown root:nut /etc/nut/upssched-cmd

# udev: grant nut group access to the UPS via both libusb and hidraw paths
cat > /etc/udev/rules.d/62-nut-cyberpower.rules << 'EOF'
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0764", ATTRS{idProduct}=="0601", GROUP="nut", MODE="0660"
SUBSYSTEM=="usb", ATTRS{idVendor}=="0764", ATTRS{idProduct}=="0601", GROUP="nut", MODE="0660"
EOF
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb
udevadm trigger --subsystem-match=hidraw
sleep 1

systemctl enable nut-server nut-monitor
systemctl reset-failed 'nut-driver@cyberpower' nut-server nut-monitor 2>/dev/null || true
systemctl restart 'nut-driver@cyberpower'
sleep 2
systemctl restart nut-server
sleep 1
systemctl restart nut-monitor

echo "=== NUT service status ==="
systemctl is-active 'nut-driver@cyberpower' nut-server nut-monitor
echo "=== UPS status ==="
upsc cyberpower@localhost ups.status battery.charge ups.load 2>/dev/null || echo "WARN: upsc failed — check driver"
ENDSSH
echo "ipc4 NUT server: done"
