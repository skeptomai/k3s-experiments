# 2026-08-03 09:55:51 by RouterOS 7.22.3
# software id = EXWY-84S5
#
# model = RB5009UG+S+
# serial number = HD808E25G27
/ip dns static
add address=192.168.88.226 name=panopticon.home.skeptomai.com type=A
add address=192.168.88.38 name=voronpurple.home.skeptomai.com type=A
add address=192.168.88.95 name=voronred.home.skeptomai.com type=A
add address=192.168.68.88 name=garagecampi.home.skeptomai.com type=A
add address=100.96.50.81 name=panlab.home.skeptomai.com type=A
add address=192.168.88.53 name=ipc1.home.skeptomai.com type=A
add address=192.168.88.52 name=ipc2.home.skeptomai.com type=A
add address=192.168.88.54 name=ipc3.home.skeptomai.com type=A
add address=192.168.88.64 name=photonmonox.home.skeptomai.com type=A
add address=192.168.89.2 comment="plex server" name=plex.home.skeptomai.com \
    type=A
add address=192.168.89.2 comment="NAS - static on bridge-nas" name=\
    nazgul.home.skeptomai.com type=A
add address=192.168.89.10 name=downloads.home.skeptomai.com type=A
add address=192.168.89.17 name=piwigo.home.skeptomai.com type=A
add address=192.168.88.1 comment="MikroTik admin" name=\
    router.home.skeptomai.com type=A
add address=192.168.88.58 comment="kube-vip control-plane VIP" name=\
    k8s-api.home.skeptomai.com type=A
add address=192.168.88.63 name=ipc7.home.skeptomai.com type=A
add address=192.168.88.64 name=ipc8.home.skeptomai.com type=A
add address=192.168.88.65 name=ipc9.home.skeptomai.com type=A
add address=192.168.88.240 comment="gruesome self-hosted platform (Traefik)" \
    name=gruesome.home.skeptomai.com type=A
add address=192.168.88.74 name=jetkvm.home.skeptomai.com type=A
add address=192.168.88.240 comment=k3s-experiment-30 name=\
    hello.home.skeptomai.com type=A
