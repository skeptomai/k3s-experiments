# Infrastructure Backlog

## Serial Console

**Status**: Hardware ready, not yet configured. Blocked on: physical serial cables.

All three ipc nodes have 16550A UART on ttyS0 (0x3f8, IRQ 4, 115200 baud). Neither
GRUB nor systemd is configured to use it.

**When cables are available:**
- Edit `/etc/default/grub` on each node, add to `GRUB_CMDLINE_LINUX`:
  `console=tty0 console=ttyS0,115200n8`
- Run `sudo update-grub`
- Enable getty: `sudo systemctl enable --now serial-getty@ttyS0.service`
- Write `scripts/enable-serial-console.sh` to do this across all three nodes at once

This gives both normal display and serial console simultaneously. Essential recovery
path if a node loses network after a botched config change.

---

## PXE Boot Server (Raspberry Pi)

**Status**: Not started. Hardware available: Pi 3B+.

**Goal**: Wipe and reinstall any ipc node from scratch via network boot, without
touching the router's core DHCP config.

**Architecture**:
- Pi 3B+ on 192.168.88.x (same subnet as ipc nodes)
- OS: Raspberry Pi OS Lite 64-bit, headless, static IP
- dnsmasq in proxy mode: intercepts PXE DHCP requests without conflicting with
  the router's DHCP server (router keeps handing out IPs)
- TFTP: serves netboot files (grubnetx64.efi for UEFI, pxelinux.0 for BIOS)
- nginx: serves Ubuntu autoinstall configs (subiquity cloud-init YAML)
  matched by MAC address per node

**Per-node autoinstall config** covers: partition layout, packages, SSH keys,
and post-install steps to rejoin the ipc node to k3s as a worker.

**Steps when ready**:
1. Image Pi with Raspberry Pi OS Lite 64-bit
2. Set static IP on 192.168.88.x, enable SSH
3. Install dnsmasq, tftpd-hpa (or use dnsmasq's built-in TFTP), nginx
4. Configure dnsmasq as DHCP proxy with TFTP root pointing at netboot files
5. Download Ubuntu 24.04 netboot files into TFTP root
6. Write per-node autoinstall YAML files (one per MAC address)
7. Configure nginx to serve autoinstall configs
8. Test: set an ipc node to network-boot first in BIOS, power cycle it

---

## Ideas / Future Experiments

- **Upgrade existing experiments** to use NFS StorageClass now that it's the default
  (experiment 04 uses local-path PVs manually — could be simplified)
- **Monitoring stack**: Prometheus + Grafana via Helm (repos already added on ipc1)
- **Cert-manager**: automatic TLS for ingress resources
- **Longhorn**: alternative distributed block storage (compare to NFS)
- **GitOps**: ArgoCD or Flux for deploying experiments from this repo automatically
