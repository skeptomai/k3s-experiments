# Spark vLLM Outage — 2026-08-28 Postmortem

## Summary

Nemotron access from gptel (Emacs) appeared to "hang" for an extended
session — no response, no error, buffer just sat there. After ruling out
several plausible-looking but wrong causes (gptel tool-call confirmation UI,
Little Snitch blocking Emacs-spawned processes), the real cause was much
simpler and had nothing to do with the client: vLLM itself had stopped
running on Spark hours earlier, following a GPU driver fault (NVIDIA Xid 13).

## What actually happened

**The outage**, confirmed via `systemctl status vllm-nemotron` on
`spark-0d93`: the service was `inactive (dead)`, `ExecStop` had run with
`code=exited, status=0/SUCCESS` — a *clean* shutdown, not a crash-looking
exit. That clean-looking exit was the red herring; it made the stop look
deliberate (a person running `systemctl stop`) rather than a fault.

**The real trigger**, found in `journalctl -k` at the exact timestamp the
service deactivated:

```
Aug 28 11:55:08 spark-0d93 kernel: NVRM: Xid (PCI:000f:01:00): 13,
  Graphics SM Global Exception on (GPC 0, TPC 1, SM 0): Multiple Warp Errors
```

91 Xid 13 events fired within the same second, across all 4 GPCs, plus one
Xid 43 ("GPU stopped processing a channel") three seconds later — the
driver-level consequence of the GPU resetting the faulting channel. vLLM's
own API server process caught the fatal GPU exception and exited gracefully
(hence the misleading `status=0/SUCCESS`) rather than being crash-killed or
stopped by a person. No SSH session or `sudo` command appears in the journal
around that time, ruling out manual intervention.

**Xid 13 is a graphics-engine exception** (illegal memory access or bad
instruction inside a GPU kernel) — not the code NVIDIA uses for thermal
shutdowns (that's Xid 79, "GPU fell off the bus," or an explicit
thermal-throttle signal, neither of which appears here). The service was
running vLLM's **nightly build** with experimental kernel backends
(`DeepGEMM E8M0`, `FlashInfer CUTLASS NvFp4 MoE backend`, FlashInfer
top-p/top-k sampling) for the NVFP4 quantization — a bug in one of those is
far more plausible than a hardware fault.

**Not a recurring pattern**: full journal history goes back to 2026-08-11
across 5 boots. Every Xid error in that entire window is this one burst.
Nothing before it, nothing since.

## Why it looked like a client-side hang

Three misleading trails were chased before finding the real cause,
worth recording so they aren't re-chased next time:

1. **gptel's tool-call confirmation UI froze the entire Emacs command
   loop** — a real, separate bug (confirmed: even `(+ 1 1)` via
   `emacsclient` timed out) — but it was a red herring for *this*
   incident, since it happened on a different request than the one
   that first surfaced the outage. Worth remembering it's a real gptel
   fragility independent of this outage; `:confirm t` was removed from
   the shell tools in dotfiles as a result (see that repo's
   `config.el`).
2. **Suspected Little Snitch blocking Emacs-spawned processes**, since a
   curl process spawned directly from Emacs via `start-process` got
   `HTTP 000, connect=0.000000s` (instant, no connection). This looked
   like a smoking gun until asked directly: does plain shell-spawned
   curl work right now? It didn't either — `Connection refused` on port
   8000, host still pingable. The server was down, full stop; nothing
   Emacs-specific about it.
3. Both of the above delayed reaching the actual fix by quite a while.
   **Lesson: verify server-side reachability from a completely
   independent process (plain shell curl) before chasing
   client-specific theories** — a hang that "looks like" it's about the
   client's process-spawning/sandboxing/firewall is worth 30 seconds of
   `curl` from a shell to rule out first.

## Fix

```bash
ssh -i ~/.ssh/Omen cb@spark-0d93 'sudo systemctl daemon-reload && sudo systemctl start vllm-nemotron'
```

(`daemon-reload` first because systemd flagged the unit file as changed on
disk since last load — unrelated pre-existing drift, not part of this
incident.) Startup took ~12–13 minutes end-to-end, not because anything was
wrong, but because the 74.8 GiB NVFP4 checkpoint exceeds the ~45 GiB RAM
available to the loading process on this box — vLLM's loader detected that
and explicitly disabled its read-ahead/prefetch optimization (logged: `"Auto-prefetch
is disabled because... checkpoint size (74.80 GiB) exceeds 90% of available
RAM (45.35 GiB)"`), since prefetching pages that get evicted before use
would waste I/O rather than save it. It falls back to reading each shard
from disk on demand instead — correct behavior given the RAM headroom, just
inherently slower than a fully page-cached load. Note DGX Spark's
Grace-Blackwell chip uses unified memory (up to 128 GB) shared between CPU
and GPU — the ~45 GiB "available RAM" is whatever was free for this process
at that moment, not the box's total memory.

Verified via `curl http://100.79.172.75:8000/v1/models` returning `HTTP
200` once the API server finished starting.

## Takeaways

1. **A clean-looking exit code doesn't mean a clean cause.** `vllm-nemotron.service`
   showed `status=0/SUCCESS` on both `ExecStart` and `ExecStop` — indistinguishable
   at a glance from a deliberate `systemctl stop`. The real cause only
   showed up in the kernel ring buffer (`journalctl -k`), not the service's
   own unit status.
2. **When a client "hangs," check server-side reachability first, from an
   independent process.** A plain `curl` from a shell (not from the
   client you're debugging) that also fails is much stronger and faster
   signal than anything inspectable from the client side.
3. **`gptel-confirm-tool-calls` / a tool's `:confirm t` can genuinely
   freeze Emacs's entire command loop** in this gptel version — confirmed
   independently of this incident, worth remembering as a standing gptel
   fragility (tracked in dotfiles, not this repo).
4. **This cluster's LLM inference depends on a single external host
   (Spark) outside k3s** — `kubectl get nodes`/pod health checks give zero
   signal about it being down, since it's not a cluster workload at all.
   Worth remembering when "the cluster looks fine but Nemotron doesn't
   respond" — check Spark directly, not the k3s cluster.
