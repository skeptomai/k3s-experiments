# Hardware Inventory — ipc1–ipc6

Authoritative hardware findings for the physical cluster, audited live on
**2026-06-28** (`/proc/cpuinfo`, `lscpu`, `free -h`, `lsblk`, `findmnt`). This is
the source of truth for CPU/RAM/disk; `node-scheduling.md` covers how roles and
taints map onto this hardware.

## Summary

| Node | CPU | Cores/Threads | RAM | Disk | Disk bus | `node-class` |
|------|-----|---------------|-----|------|----------|--------------|
| ipc1 | Pentium Gold G5400T @ 3.10 GHz | 2c / 4t | 30 GiB | 238.5 GB SATA SSD (`DEM28-B56M41BW1D`) | SATA | standard |
| ipc2 | Pentium Gold G5400T @ 3.10 GHz | 2c / 4t | 30 GiB | 238.5 GB SATA SSD (`DEM28-B56M41BW1D`) | SATA | standard |
| ipc3 | Pentium Gold G5400T @ 3.10 GHz | 2c / 4t | 30 GiB | 238.5 GB SATA SSD (`DEM28-B56M41BW1D`) | SATA | standard |
| ipc4 | Core i5-12500T (12th Gen) | 6c / 12t | 30 GiB | 238.5 GB NVMe (Samsung `MZVL2256HCHQ-00BH1`) | NVMe | performance |
| ipc5 | Core i5-12500T (12th Gen) | 6c / 12t | 30 GiB | 238.5 GB NVMe (Samsung `MZVL2256HCHQ-00BH1`) | NVMe | performance |
| ipc6 | Core i5-12500T (12th Gen) | 6c / 12t | 30 GiB (2×16 GiB) | 238.5 GB NVMe (Samsung `MZVL2256HCHQ-00BH1`) | NVMe | performance |

All six: **Ubuntu 26.04 LTS**, kernel **7.0.0-27-generic**, root on **ext4**,
container runtime **pelagos** (`unix:///run/pelagos/cri.sock`).

## Two hardware classes

- **`standard` (ipc1-3)** — Pentium Gold G5400T, 2 cores / 4 threads, **SATA SSD**.
  Weak CPUs (the reason for the `slow:NoSchedule` taint), but plenty of RAM and a
  real SSD. Well suited to light, always-on, latency-tolerant duty — i.e. the
  **control plane / etcd**.
- **`performance` (ipc4-6)** — Core i5-12500T, 6 cores / 12 threads, **NVMe SSD**.
  These carry all real workloads.

## Disk detail (relevant to etcd)

- **ipc1-3: `DEM28-B56M41BW1D`** — an Innodisk SATADOM-class industrial SATA flash
  module, 238.5 GB, `rotational=0`. SATA SSD fsync latency is sub-millisecond to low
  single-digit ms — comfortably inside etcd's tolerance (etcd warns around 10 ms+
  fsync). SATADOM modules have modest *sustained* write IOPS vs. consumer SSDs, but
  etcd's small sequential WAL fsyncs are a fine fit. **Verdict: adequate for a
  3-node etcd quorum.**
- **ipc4-6: Samsung `MZVL2256HCHQ-00BH1`** (PM9A1-class OEM NVMe), 238.5 GB — fast
  NVMe, appropriate for workload I/O.

## Notes / history

- **ipc6 RAM upgrade (2026-06-28):** ipc6 was upgraded from 16 GB to **2×16 GiB**
  modules, now reporting 30 GiB like the rest of the fleet. The old "less RAM than
  ipc4/5" caveat in `node-scheduling.md` has been corrected. **All six nodes now
  report 30 GiB** — the fleet is RAM-uniform.

## Method

```bash
for n in ipc1 ipc2 ipc3 ipc4 ipc5 ipc6; do
  ssh $n '
    grep -m1 "model name" /proc/cpuinfo
    lscpu | grep -E "^(Core|Socket|Thread)"
    free -h | awk "/^Mem:/{print \$2}"
    lsblk -d -o NAME,SIZE,ROTA,TRAN,MODEL
    findmnt -no SOURCE,FSTYPE /
    uname -r; . /etc/os-release; echo $PRETTY_NAME'
done
```
