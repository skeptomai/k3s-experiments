# PXE Boot / Autoinstall

Unattended Ubuntu 24.04 reinstall for ipc1/ipc2/ipc3 via netboot.xyz on nazgul.

## Infrastructure

- **TFTP + netboot.xyz**: nazgul (192.168.89.2), port 69/UDP — netboot.xyz SCALE app
- **Autoinstall HTTP**: nazgul (192.168.89.2), port 31011 — netboot.xyz assets server
- **MikroTik DHCP**: bridge-lan configured with `next-server=192.168.89.2`, `boot-file-name=netboot.xyz.efi`

## Node → MAC → config mapping

| Node | MAC | Autoinstall URL |
|------|-----|-----------------|
| ipc1 | a8:a1:59:43:2a:67 | `http://192.168.89.2:31011/autoinstall/a8-a1-59-43-2a-67/` |
| ipc2 | a8:a1:59:43:2a:74 | `http://192.168.89.2:31011/autoinstall/a8-a1-59-43-2a-74/` |
| ipc3 | a8:a1:59:43:2a:ed | `http://192.168.89.2:31011/autoinstall/a8-a1-59-43-2a-ed/` |

## Deploying configs to nazgul

The `autoinstall/` directory must be copied to the netboot.xyz assets volume on nazgul.
Find the assets path in TrueNAS SCALE under Apps → netbootxyz → Edit → Storage, then:

`scp -r pxe/autoinstall root@nazgul:/path/to/assets/`

## netboot.xyz custom menu entry

In the netboot.xyz web UI (http://192.168.89.2:31010), add a custom menu entry for
each node. Example for ipc1:

```
#!ipxe
kernel http://boot.netboot.xyz/ubuntu/24.04/amd64/linux autoinstall quiet net.ifnames=0 biosdevname=0 ip=dhcp ds=nocloud-net;s=http://192.168.89.2:31011/autoinstall/a8-a1-59-43-2a-67/
initrd http://boot.netboot.xyz/ubuntu/24.04/amd64/initrd
boot
```

## Post-install k3s setup

After OS install, use the scripts in `scripts/` to install k3s:
- ipc1: install as server (control plane)
- ipc2/ipc3: install as agents pointing at ipc1

The autoinstall config installs `nfs-common` so NFS PVC storage works immediately.
Passwordless sudo is configured for `cb`.

## What the autoinstall does NOT do

- Install k3s (handled by repo scripts post-install)
- Set static IPs (DHCP from MikroTik, same as current setup)
- Configure serial console (pending serial cable availability)
