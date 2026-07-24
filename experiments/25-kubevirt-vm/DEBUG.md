# KubeVirt VMI cirros-test Debug Log

**Setup:** KubeVirt v1.8.4, Pelagos CRI v0.65.52, k3s v1.35.5, libvirt 11.9.0, QEMU 10.1.0  
**VMI spec:** `experiments/25-kubevirt-vm/vmi-cirros.yaml` (pinned to ipc8)  
**Top-level error:** `virError(Code=1, Domain=0, Message='An error occurred, but the cause is unknown')`

---

## What is PROVEN (not assumed)

### QEMU never exec's
`sched:sched_process_exec` is a kernel-level tracepoint that fires for every execve/execveat
on the entire system, regardless of namespace or UID. A bpftrace run with this probe and
**no UID filter** — filtering only on `/usr/libexec/qemu-kvm` as the filename — captured
**zero exec events** for the actual VM QEMU during the VMI start window.

The two probe QEMUs (capability detection) DO exec — they appeared in earlier UID=107
filtered traces. The actual VM QEMU does not.

### The QEMU log content is written by libvirt, not QEMU
`/var/run/kubevirt-private/libvirt/qemu/log/default_cirros-test.log` contains:
```
2026-07-15 13:01:19.676+0000: starting up libvirt version: 11.9.0, ...
LC_ALL=C \ [full QEMU command] \
libvirt:  error : libvirtd quit during handshake: Input/output error
2026-07-15 13:01:19.683+0000: shutting down, reason=failed
```
All four lines are written by **libvirt** (via virtlogd), not QEMU. Libvirt writes the startup
header and command line to the log **before** exec'ing QEMU. When the pre-exec child dies
without exec'ing, libvirt writes the handshake error and shutdown lines as cleanup.
**"Starting up" is NOT proof that QEMU ran.**

### The libvirt hooks work fine
Four hook invocations of `/etc/libvirt/hooks/qemu` happen during the domain start sequence.
All four exit with **code=0**. Hooks are not the problem.

### The pre-exec child exits without exec'ing, code=0
From `bpftrace-hook-exits.bt` (which tracks all forks/execs/exits from UID=107 processes):
```
[8079] EXIT_GROUP pid=2661795 comm=rpc-virtqemud code=0 (parent=2661632)
```
This process — the actual VM's pre-exec child — exits with code=0 and no EXEC event before it.
The probe QEMUs' pre-exec children DO exec (we see them). This one does not.

A second process (child of the pre-exec child) writes the error to stderr:
```
[8086] CHILD_STDERR pid=2661796 comm=rpc-virtqemud: libvirt:  error : libvirtd quit during handshake: Input/output error
[8086] EXIT_GROUP pid=2661796 comm=rpc-virtqemud code=0 (parent=2661795)
```

### Compute container capabilities
The compute container explicitly has:
```yaml
securityContext:
  capabilities:
    drop: [ALL]
    add: [NET_BIND_SERVICE]
  runAsUser: 107
  runAsGroup: 107
  runAsNonRoot: true
  allowPrivilegeEscalation: false
```
CapEff = 0x0000000000000400 (bit 10 = CAP_NET_BIND_SERVICE only). This is intentional
KubeVirt design, not a Pelagos bug. KubeVirt is supposed to work with this cap set.

### The probe QEMUs work
The probe QEMUs (run by libvirt for capability detection, with `-daemonize` in their
command line) exec and exit normally. Their pre-exec children also show `capset EPERM`
and `rt_sigaction EINVAL` failures before exec — but they proceed to exec despite those.
This confirms those failures are benign and expected.

---

## What the QEMU command would have been

Full command captured from the log file (libvirt writes this before attempting exec):

```
LC_ALL=C PATH=... HOME=/home/qemu USER=root XDG_CACHE_HOME=...
/usr/libexec/qemu-kvm
  -name guest=default_cirros-test,debug-threads=on
  -S
  -machine pc-q35-rhel9.8.0,...
  -accel kvm
  -cpu SierraForest,...
  -m size=262144k
  -chardev socket,id=charmonitor,fd=20,server=on,wait=off    ← QMP monitor, fd inherited
  -mon chardev=charmonitor,id=monitor,mode=control
  -blockdev file,filename=/var/run/kubevirt/container-disks/disk_0.img,...  ← backing
  -blockdev file,filename=/var/run/kubevirt-ephemeral-disks/disk-data/containerdisk/disk.qcow2,...  ← writable
  -netdev type=tap,fd=21,vhost=true,vhostfd=23,...           ← tap/vhost fds inherited
  -chardev socket,id=charserial0,fd=17,...                   ← serial console fd
  -chardev socket,id=charchannel0,fd=18,...                  ← virtio-serial fd
  -add-fd set=0,fd=19,...                                    ← serial log fd
  -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny
```

Key observations:
- **fd=20, 21, 23, 17, 18, 19** are all inherited from the pre-exec child via dup2
- **disk_0.img** is at `/var/run/kubevirt/container-disks/disk_0.img` (inside container namespace)
- **disk.qcow2** is the writable ephemeral layer
- **`-sandbox on,resourcecontrol=deny`** — QEMU seccomp sandbox with cgroup syscalls denied
- **`USER=root`** in env despite running as uid=107 (libvirt sets this; no actual root access)

---

## libvirt / virtqemud configuration

`/etc/libvirt/qemu.conf` (inside compute container, read-only):
```
stdio_handler = "logd"
vnc_listen = "0.0.0.0"
user = "qemu"
group = "qemu"
dynamic_ownership = 1
remember_owner = 0
namespaces = [ ]
cgroup_controllers = [ ]
```

`virtqemud.conf`:
```
listen_tls = 0
listen_tcp = 0
log_outputs = "1:stderr"
```

---

## What has been ruled out

| Thing investigated | Result |
|---|---|
| Pelagos SECBIT_KEEP_CAPS bug | Fixed in v0.65.50 — virt-launcher now starts |
| pasta AppArmor blocking | Fixed 2026-07-14 — `/run/pelagos/pasta-ns/* r,` on all nodes |
| libvirt hooks failing | Proven not the problem — all 4 exit code=0 |
| initgroups/CAP_SETGID failure | Dead end. libvirt ignores EPERM from setgroups for non-root. Probes work with same caps. |
| "containerdisk not ready" error | Secondary symptom only — appears after the primary failure |
| QEMU running and crashing | Disproven — QEMU never exec's |
| cgroup write failing (inside QEMU) | Irrelevant until QEMU actually runs |

---

## ROOT CAUSE FOUND (2026-07-16) — strace on virtqemud (REVISED 2026-07-16)

`scripts/strace-preexec.sh` attached `strace -f` to the running virtqemud process.
Subsequent run with `scripts/strace-abort-window.sh` (broader filter including
`access`, `stat`, `socket`) revealed the true fatal check.

### What actually happens

The pre-exec launch uses **two child processes**:

1. **Pre-exec parent** (pid=2929321): clears CLOEXEC on all QEMU fds (QMP socket fd=21,
   tap fd=22, vhost fd=24, serial fds 18/19/20, signaling pipes 26/27), redirects
   stdin/stdout/stderr, then `clone()`s the QEMU-to-be (container PID=79 = host PID=2929323).
   Then waits on a pipe for the QEMU-to-be to signal "ready", and exits when signaled.

2. **QEMU-to-be** (pid=2929323, container PID=79): writes its own PID to
   `/var/run/libvirt/qemu/run/default_cirros-test.pid`, signals ready to parent
   via pipe, then **blocks on a second pipe (fd=27, pipe:[17323632]) waiting for
   virtqemud to signal "proceed with exec"**.

The virtqemud thread receives the "ready" signal, then does exactly two checks before
aborting:

```
openat("/sys/devices/intel_cqm/type", O_RDONLY) = -1 ENOENT   ← gracefully handled
access("/sys/devices/system/cpu/online", F_OK) = -1 ENOENT     ← FATAL
close(28<pipe:[17323632]>)   ← sends EOF = ABORT to QEMU-to-be
```

The intel_cqm check is **gracefully handled** by `virPerfNew()` →
`virPerfRdtAttrInit()` → `virFileReadAllQuiet()` → `virResetLastError()`.
The **cpu/online check is fatal**: libvirt cannot determine which CPUs are online,
cannot set up vCPU affinity/topology, and aborts the domain launch.

### Root cause: Pelagos does not mount sysfs in containers

The compute container has **no sysfs mounted at `/sys/`**. Only `/sys/fs/cgroup`
(cgroup2) exists. `/sys/devices/` does not exist at all.

Confirmed in virtqemud's mount namespace (`/proc/mounts`):
```
cgroup2 /sys/fs/cgroup cgroup2 ro,relatime,nsdelegate,...
# NO: sysfs /sys sysfs ...
```

The host has `/sys/devices/system/cpu/online` (shows `0-11`).
The virt-launcher monitor container has full sysfs.
The compute container (virtqemud) does not.

**This is a Pelagos CRI bug.** The OCI runtime spec requires default mounts including
a read-only sysfs at `/sys/` for all containers. Standard runtimes (runc, crun)
implement this. Pelagos does not mount sysfs in non-privileged containers.

libvirt's `virHostCPUGetOnlineBitmap()` is called during domain startup to determine
which CPUs are online (for vCPU affinity/NUMA setup). When
`/sys/devices/system/cpu/online` returns ENOENT, libvirt treats this as a fatal
error and aborts the QEMU launch via the proceed pipe.

This explains why this has never been reported: standard container runtimes always
mount sysfs, so `/sys/devices/system/cpu/online` is always accessible in containers.
Only Pelagos omits the sysfs mount.

### Fix options

| Option | Notes |
|--------|-------|
| Fix Pelagos to mount sysfs | Correct long-term fix — **filed as Pelagos #452** |
| Mount `/sys/devices/system` via hostPath volume in compute container (virt-controller patch) | **IMPLEMENTED** — `skeptomai/kubevirt@fix/virt-controller-two-pod-race` commit 5256cb1 |

---

## Additional confirmation: QMP socket never created (2026-07-16)

`bpftrace-virtqemud-qmp.bt` (socket-level tracing of all UID=107 processes) ran during
a VMI start attempt and found: after the libvirt hooks complete, virtqemud attempts to
`connect()` to the QEMU QMP monitor socket path and gets **ENOENT** twice. This is
consistent with QEMU never exec'ing — no QMP socket was ever created. The bpftrace also
confirmed zero `socketpair()` events during domain creation (libvirt uses path-based
Unix sockets, not socketpairs, for QMP).

The two child processes visible in this run:
- `pid=2785069` (pre-exec child): closes fds 23, 29, 4 and exits comm=`rpc-virtqemud` — no exec before exit
- `pid=2785070` (child of pre-exec child): closes fd=4, writes the handshake error to stderr, exits

This matches the prior session's `bpftrace-hook-exits.bt` findings exactly.

---

## Next steps (root cause known — Pelagos sysfs missing)

Root cause confirmed: Pelagos does not mount sysfs in the compute container.

**Option A: fix Pelagos** — add sysfs to default container mounts. This is the correct
long-term fix. File against Pelagos issue tracker.

**Option B: hostPath workaround** — add a volume+volumeMount for `/sys/devices/system`
via `customizeComponents` in the KubeVirt CR, binding the host's
`/sys/devices/system/cpu/` into the compute container. This would give libvirt access to
`cpu/online` without a Pelagos fix.

**What we do NOT know yet:** whether the same failure happens on ipc4-7/ipc9 (the VMI
is pinned to ipc8 but Pelagos behavior is the same on all nodes — all would lack
sysfs in containers).

---

## SSH / tracing notes

- Jump host (ipc4 → ipc8) is stable. Earlier failures were due to chaining `sleep N`
  inside a single SSH command — use separate SSH calls instead.
- bpftrace scripts live in `scripts/` on omen; copy to `/tmp/` on ipc8 before use.
- bpftrace must be started BEFORE `kubectl apply` to catch events.
- Pattern that works: `ssh ipc8 "sudo bpftrace ... > /tmp/log 2>&1 &"` (SSH closes
  immediately, bpftrace keeps running), then separate SSH to collect.

---

## Relevant bpftrace scripts

| Script | Purpose |
|---|---|
| `scripts/bpftrace-hook-exits.bt` | Tracks all UID=107 forks/execs/exits + stderr. Best overall view. |
| `scripts/bpftrace-qemu.bt` | Tracks qemu-kvm exec/stderr/exit. UID filtered. |
| `scripts/bpftrace-uid107-fails.bt` | All failed syscalls from UID=107 processes. |
| `/tmp/qemu-exec-trace.bt` (on ipc8) | No-UID-filter exec trace for /usr/libexec/qemu-kvm. Proved QEMU doesn't exec. |
