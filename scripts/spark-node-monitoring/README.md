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
| `gpu-xid-exporter.sh` | `/usr/local/bin/gpu-xid-exporter.sh` |
| `gpu-xid-exporter.service` / `.timer` | `/etc/systemd/system/` |
| `spark-thermal-exporter.sh` | `/usr/local/bin/spark-thermal-exporter.sh` |
| `spark-thermal-exporter.service` / `.timer` | `/etc/systemd/system/` |
| `disable-eee.service` | `/etc/systemd/system/disable-eee.service` |
| `wifi-powersave-off.conf` | `/etc/NetworkManager/conf.d/wifi-powersave-off.conf` |
| `vllm-nemotron.service` | `/etc/systemd/system/vllm-nemotron.service` |

### `gpu-xid-exporter.sh` / `.service` / `.timer`

Added 2026-08-29 after a GPU driver fault (NVIDIA Xid 13, see
`docs/spark-vllm-xid13-postmortem.md`) silently crashed vLLM's engine with
no alerting anywhere to catch it. Counts Xid occurrences from the current
boot's kernel ring buffer (`journalctl -k -b 0`), exposed as
`spark_gpu_xid_errors_total{xid="N"}` (a counter, one series per distinct
Xid code seen). Alerting lives in the `home-monitoring` repo
(`pelagos/config/prometheus/rules/alerts.yml`, `SparkGPUXidError`) and fires
on any `increase()` — unlike temperature, there's no "elevated but fine"
tier for a Xid, any occurrence is a real fault worth paging on.

### `vllm-nemotron.service`

Runs the Nemotron-3-Super-120B-A12B-NVFP4 vLLM server under Pelagos
(`eugr/spark-vllm:nightly-20260805`, port 8000). Added 2026-08-19 after
discovering this container had **no persistence at all** — it had only ever
been started by hand (the exact command was buried in a
[k3s-experiments#16](https://github.com/skeptomai/k3s-experiments/issues/16)
comment) and didn't survive the reboot from the wired-move. This unit
restores it on boot and on crash.

Install:
```bash
sudo cp vllm-nemotron.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vllm-nemotron.service
```

Check readiness (model load takes ~4-5min): `curl -s localhost:8000/v1/models`.

**Known Pelagos CLI quirk:** `--ulimit memlock=unlimited` (the syntax
originally used interactively) is rejected by the current Pelagos version —
it now requires `SOFT:HARD` as literal integers, no `unlimited` keyword.
Worked around with `memlock=18446744073709551615:18446744073709551615`
(u64::MAX). Not filed upstream since it's a minor ergonomics regression, not
a functional blocker — revisit if it gets more annoying.

**`--reasoning-parser nemotron_v3`** (added 2026-08-19): after a handful of
gptel interactions via this server, the model occasionally emitted a
plausible-looking but fake agent-framework error as its actual reply content
(e.g. `[ERROR: Agent failed (Function process_single_item_agent timed out
after 90.0 seconds), API failed (API request returned None after all
retries)]`) — confirmed via server logs that every request that session
returned a clean `200 OK`, so nothing actually failed at the vLLM/infra
level; the model hallucinated the error text itself, plausibly having been
trained on agent-benchmark transcripts full of this exact kind of log
format. Without `--reasoning-parser`, vLLM has no configured way to
separate/strip Nemotron's `<think>`/`</think>` reasoning-trace content from
the visible response even with `chat_template_kwargs:
{"enable_thinking": false}` set client-side (gptel's Spark backend, see
`dotfiles/doomemacs/doom/config.el`) — any imperfect suppression would have
nowhere to go but straight into `content`. Adding vLLM's built-in
`nemotron_v3` reasoning parser gives leaked reasoning content a dedicated
`reasoning` field in the API response instead (confirmed present, `null`,
in a clean test response after this change) rather than bleeding into the
visible reply. Not a guaranteed fix for a hallucination (that's inherent
model behavior), but removes one concrete mechanism that could produce it.

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
sudo systemctl enable --now node_exporter gpu-temp-exporter.timer gpu-xid-exporter.timer spark-thermal-exporter.timer disable-eee.service
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
- `docs/spark-vllm-xid13-postmortem.md` — the 2026-08-28 Xid 13 incident that motivated the Xid exporter/alert
- `home-monitoring/pelagos/config/prometheus/prometheus.yml` — `spark_node_exporter` scrape job
- `home-monitoring/pelagos/config/prometheus/rules/alerts.yml` — `spark.thermal` alert group (temps + `SparkGPUXidError`)
- `home-monitoring/pelagos/config/grafana/provisioning/dashboards/node-temperatures.json` — spark panels
