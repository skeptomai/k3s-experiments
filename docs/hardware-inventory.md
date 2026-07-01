# Hardware Inventory — ipc1–ipc9

Authoritative hardware findings for the physical cluster. ipc1-6 audited
**2026-06-28**; **ipc7-9 added 2026-06-30** (`/proc/cpuinfo`, `lscpu`, `free -h`,
`lsblk`). This is the source of truth for CPU/RAM/disk; `node-scheduling.md` covers
roles/taints. **ipc7-9 (HP Elite Mini 800 G9 workers) joined the cluster 2026-07-01.**

## Summary

| Node | CPU | Cores/Threads | RAM | Disk | Disk bus | `node-class` |
|------|-----|---------------|-----|------|----------|--------------|
| ipc1 | Pentium Gold G5400T @ 3.10 GHz | 2c / 4t | 30 GiB | 238.5 GB SATA SSD (`DEM28-B56M41BW1D`) | SATA | standard |
| ipc2 | Pentium Gold G5400T @ 3.10 GHz | 2c / 4t | 30 GiB | 238.5 GB SATA SSD (`DEM28-B56M41BW1D`) | SATA | standard |
| ipc3 | Pentium Gold G5400T @ 3.10 GHz | 2c / 4t | 30 GiB | 238.5 GB SATA SSD (`DEM28-B56M41BW1D`) | SATA | standard |
| ipc4 | Core i5-12500**T** (35W, 12th Gen) | 6c / 12t | 30 GiB | 238.5 GB NVMe (Samsung `MZVL2256HCHQ-00BH1`) | NVMe | performance |
| ipc5 | Core i5-12500**T** (35W, 12th Gen) | 6c / 12t | 30 GiB | 238.5 GB NVMe (Samsung `MZVL2256HCHQ-00BH1`) | NVMe | performance |
| ipc6 | Core i5-12500**T** (35W, 12th Gen) | 6c / 12t | 30 GiB (2×16 GiB) | 238.5 GB NVMe (Samsung `MZVL2256HCHQ-00BH1`) | NVMe | performance |
| ipc7 | Core i5-12500 (**65W non-T**, 12th Gen) | 6c / 12t | **14 GiB (16 GB)** | 238.5 GB NVMe (Samsung `MZVL2256HCHQ-00BH1`) | NVMe | fastest |
| ipc8 | Core i5-12500 (**65W non-T**, 12th Gen) | 6c / 12t | **14 GiB (16 GB)** | 238.5 GB NVMe (Samsung `MZVL2256HCHQ-00BH1`) | NVMe | fastest |
| ipc9 | Core i5-12500 (**65W non-T**, 12th Gen) | 6c / 12t | **14 GiB (16 GB)** | 238.5 GB NVMe (Samsung `MZVL2256HCHQ-00BH1`) | NVMe | fastest |

All nine: **Ubuntu 26.04 LTS**, pelagos CRI, `v1.35.5+k3s1`. ipc7-9 joined 2026-07-01
(i5-12500 non-T, 16 GB — all three verified live; manual OS install, not PXE).

## Hardware classes

- **`standard` (ipc1-3)** — Pentium Gold G5400T, 2c/4t, **SATA SSD**. Weak CPUs (the
  `slow:NoSchedule` taint), plenty of RAM. Light, always-on duty → the **control
  plane / etcd**.
- **`performance` (ipc4-6)** — Core i5-12500**T** (35W), 6c/12t, **32 GB** RAM,
  **NVMe SSD**. Carry all standard workloads.
- **`fastest` (ipc7-9)** — Core i5-12500 (**65W non-T** — higher base clock 3.0 vs
  2.0 GHz, highest sustained all-core clocks, hotter/more power), 6c/12t, **16 GB**
  RAM (half of ipc4-6; upgradeable via the G9's 2× DDR5 SO-DIMM slots), **NVMe SSD**.
  The fastest tier for CPU-bound work (builds, tests). Different SKU — bought on
  availability. (Chassis: all six i5 nodes are HP Elite Mini 800 G9.)

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
