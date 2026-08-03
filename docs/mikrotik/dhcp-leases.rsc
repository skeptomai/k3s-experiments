# 2026-08-03 09:55:51 by RouterOS 7.22.3
# software id = EXWY-84S5
#
# model = RB5009UG+S+
# serial number = HD808E25G27
/ip dhcp-server lease
add address=192.168.88.38 client-id=1:dc:a6:32:bc:87:33 mac-address=\
    DC:A6:32:BC:87:33 server=defconf
add address=192.168.88.226 client-id=1:a4:bb:6d:d0:5b:7e mac-address=\
    A4:BB:6D:D0:5B:7E server=defconf
add address=192.168.88.95 client-id=1:e4:5f:1:3a:20:f4 mac-address=\
    E4:5F:01:3A:20:F4 server=defconf
add address=192.168.88.30 client-id=1:9e:6b:0:14:fa:a mac-address=\
    9E:6B:00:14:FA:0A server=defconf
add address=192.168.89.11 client-id=1:9e:6b:0:14:fa:a mac-address=\
    9E:6B:00:14:FA:0A server=dhcp-nas
add address=192.168.89.10 client-id=1:9e:6b:0:50:aa:9f mac-address=\
    9E:6B:00:50:AA:9F server=dhcp-nas
add address=192.168.89.17 client-id=1:9e:6b:0:74:2c:12 mac-address=\
    9E:6B:00:74:2C:12 server=dhcp-nas
add address=192.168.89.2 comment="nazgul static" mac-address=\
    98:B7:85:00:E1:00 server=dhcp-nas
add address=192.168.88.52 mac-address=A8:A1:59:43:2A:ED server=defconf
add address=192.168.88.54 mac-address=A8:A1:59:43:2A:74 server=defconf
add address=192.168.88.53 mac-address=A8:A1:59:43:2A:67 server=defconf
add address=192.168.88.55 comment=ipc4 mac-address=D0:AD:08:9C:D2:CB server=\
    defconf
add address=192.168.88.56 comment=ipc5 mac-address=D0:AD:08:9C:D1:45 server=\
    defconf
add address=192.168.88.57 comment=ipc6 mac-address=E0:73:E7:C0:B0:08 server=\
    defconf
add address=192.168.88.110 client-id=1:48:da:35:6f:38:97 comment=\
    "ipc4-nanokvm (Sipeed NanoKVM Lite)" mac-address=48:DA:35:6F:38:97 \
    server=defconf
add address=192.168.88.63 comment=ipc7 mac-address=E0:73:E7:3A:A6:7B server=\
    defconf
add address=192.168.88.64 comment=ipc8 mac-address=7C:4D:8F:AA:FA:A4 server=\
    defconf
add address=192.168.88.65 comment=ipc9 mac-address=7C:4D:8F:AA:EF:73 server=\
    defconf
add address=192.168.88.73 client-id=1:b8:27:eb:68:3b:f7 comment=\
    "prusa-xl-camera (Pi 3B+, camera streamer, Prusa XL)" mac-address=\
    B8:27:EB:68:3B:F7 server=defconf
add address=192.168.88.70 client-id=1:dc:a6:32:1e:be:3f comment=\
    "pikvm (Geekworm KVM-A3, Pi 4B)" mac-address=DC:A6:32:1E:BE:3F server=\
    defconf
add address=192.168.88.74 client-id=1:30:52:53:c:4f:d5 comment=\
    "jetkvm (ipc5)" mac-address=30:52:53:0C:4F:D5 server=defconf
add address=192.168.88.160 client-id=1:dc:a6:32:ca:2d:32 comment=\
    "prusa-mk4-camera (Pi 4B, camera streamer)" mac-address=DC:A6:32:CA:2D:32 \
    server=defconf
add address=192.168.88.31 comment="cluster-power-strip (Kasa HS300, ipc4-9)" \
    mac-address=6C:5A:B0:15:ED:72 server=defconf
