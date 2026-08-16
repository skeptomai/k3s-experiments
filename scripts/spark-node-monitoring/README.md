# spark-0d93 node monitoring

Standalone setup on the DGX Spark (spark-0d93, k3s-experiments#16) — not
GitOps-managed (spark isn't a k3s node), so these files are a manual
reference/backup, not auto-deployed. Re-apply by hand if spark is ever
reinstalled.

## Why this exists

node_exporter's built-in `hwmon`/`thermal_zone`/`cpufreq` collectors do
hundreds of sequential synchronous `sysfs` reads on this hardware and were
blocking every HTTP response behind an internal lock for 15s+ (confirmed via
`strace` — see #16). They're permanently disabled; CPU/NVMe/GPU/WiFi-radio
temperatures instead come from two independent scripts on 30s systemd
timers, writing to node_exporter's textfile collector.

## Files

| File | Installs to |
|------|-------------|
| `node_exporter.service` | `/etc/systemd/system/node_exporter.service` |
| `gpu-temp-exporter.sh` | `/usr/local/bin/gpu-temp-exporter.sh` |
| `gpu-temp-exporter.service` / `.timer` | `/etc/systemd/system/` |
| `spark-thermal-exporter.sh` | `/usr/local/bin/spark-thermal-exporter.sh` |
| `spark-thermal-exporter.service` / `.timer` | `/etc/systemd/system/` |
| `disable-eee.service` | `/etc/systemd/system/disable-eee.service` |
| `wifi-powersave-off.conf` | `/etc/NetworkManager/conf.d/wifi-powersave-off.conf` |

## Install (fresh spark)

```bash
sudo apt-get install -y lm-sensors
# node_exporter binary: download the aarch64 build from
# https://github.com/prometheus/node_exporter/releases, install to
# /usr/local/bin/node_exporter
sudo useradd -rs /bin/false node_exporter
sudo mkdir -p /var/lib/node_exporter/textfile_collector
sudo chown -R node_exporter:node_exporter /var/lib/node_exporter
# copy all files above to their target paths, chmod +x the two .sh scripts
sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter gpu-temp-exporter.timer spark-thermal-exporter.timer disable-eee.service
sudo nmcli connection reload
```

## Other spark-specific config NOT captured in these files

- **WiFi BSSID pinned** to a specific AP radio (`802-11-wireless.bssid` in
  the `samsara` NetworkManager connection, which syncs into
  `/etc/netplan/90-NM-<uuid>.yaml` automatically) — done to stop the
  driver's frequent inter-BSSID roaming (documented MT7925 issue). That
  netplan file also contains the WiFi password in plaintext, so it's
  deliberately not copied into this repo. To reapply after a reinstall:
  `sudo nmcli connection modify samsara 802-11-wireless.bssid <BSSID>` then
  `sudo nmcli connection up samsara`. Check current BSSID candidates via
  `nmcli connection show samsara | grep seen-bssids` and pick whichever has
  the best `iw dev wlP9s9 link` signal.
- **`/etc/hosts` entries** for the k3s cluster nodes (`ipc4`-`ipc9`,
  `nazgul`) — added because the ipc nodes don't run `avahi-daemon` (minimal
  Ubuntu server autoinstall doesn't include it) and mDNS doesn't cross the
  bridge-lan/bridge-nas boundary to reach nazgul either way (see
  orgfiles `home-network/mdns.md`). See CLAUDE.md's node table for current
  IPs if these need updating.
- **Ethernet not yet connected** — `enP7s7` is up but no cable. The EEE fix
  above is pre-installed and takes effect automatically once it's wired.

## See also

- [k3s-experiments#16](https://github.com/skeptomai/k3s-experiments/issues/16) — full narrative: Pelagos GPU passthrough, vLLM/NVFP4 deployment, this monitoring work
- `home-monitoring/pelagos/config/prometheus/prometheus.yml` — `spark_node_exporter` scrape job
- `home-monitoring/pelagos/config/prometheus/rules/alerts.yml` — `spark.thermal` alert group
- `home-monitoring/pelagos/config/grafana/provisioning/dashboards/node-temperatures.json` — spark panels
