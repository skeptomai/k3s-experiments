#!/bin/bash
# Entry point for the personal dev pod. Runs as root (sshd requires it for
# privilege separation / dropping to the login user) and handles the two
# things that can't be baked into the image because they depend on the
# runtime PVC/Secret mounts:
#
#   1. SSH host keys -- generated once into a persistent PVC subPath so
#      they survive pod reschedule (no "host key changed" warnings).
#   2. authorized_keys -- copied in from the Secret-mounted pubkey (see
#      manifests/personal-dev-pod/deployment.yaml) and re-chowned/chmod'd,
#      since Secret-mounted files come in root-owned and the home
#      directory itself may be created wide-open on first NFS
#      provisioning (nfs-subdir-provisioner doesn't know the pod's uid in
#      advance). sshd's StrictModes rejects a group/other-writable
#      home/.ssh or a non-owned authorized_keys, so this has to be fixed
#      up every start, not just once.
set -euo pipefail

# Defense in depth, not just belt-and-suspenders: the Dockerfile's
# build-time `mkdir -p /run/sshd` assumes the container runtime always
# gives a fresh, empty /run tmpfs at start, so that directory (owned
# root:root from the build) is what sshd sees. That assumption broke on
# ipc7 specifically (confirmed 2026-10-01, not reproducible on ipc8/ipc9
# on the same Pelagos version) -- its CRI failed to mount a fresh tmpfs
# over /run, so the container's own image-layer /run/sshd showed through
# unmasked, frozen at image-build time and group-owned by the HOST's
# `pelagos` service group (983) -- a namespace leak, not just a missing
# directory. sshd's StrictModes then refuses to start ("must be owned by
# root and not group or world-writable"), permanent CrashLoopBackOff. This
# re-asserts correct ownership every start regardless of what the runtime
# handed us, independent of whatever's actually wrong in Pelagos CRI on
# that node -- reported upstream as pelagos-containers/pelagos#559.
mkdir -p /run/sshd
chown root:root /run/sshd
chmod 0755 /run/sshd

HOME_DIR=/home/cb
HOSTKEY_DIR=/etc/ssh/host_keys
PUBKEY_SRC=/etc/ssh-pubkey/authorized_keys

mkdir -p "$HOSTKEY_DIR"
[ -f "$HOSTKEY_DIR/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -f "$HOSTKEY_DIR/ssh_host_ed25519_key" -N ''
[ -f "$HOSTKEY_DIR/ssh_host_rsa_key" ] || ssh-keygen -q -t rsa -b 4096 -f "$HOSTKEY_DIR/ssh_host_rsa_key" -N ''
chown root:root "$HOSTKEY_DIR"/ssh_host_*_key
chmod 600 "$HOSTKEY_DIR"/ssh_host_*_key

mkdir -p "$HOME_DIR/.ssh"
if [ -f "$PUBKEY_SRC" ]; then
  cp "$PUBKEY_SRC" "$HOME_DIR/.ssh/authorized_keys"
fi

# Non-recursive on $HOME_DIR itself -- it can hold a large cargo
# target/registry tree after real builds, and only the top-level dir and
# .ssh/ matter for sshd's StrictModes checks.
chown cb:cb "$HOME_DIR"
chmod 750 "$HOME_DIR"
chown -R cb:cb "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"
[ -f "$HOME_DIR/.ssh/authorized_keys" ] && chmod 600 "$HOME_DIR/.ssh/authorized_keys"

exec /usr/sbin/sshd -D -e
