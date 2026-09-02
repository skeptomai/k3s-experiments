# NVIDIA Xid Error Reference

Quick reference for interpreting NVIDIA Xid errors on Spark (spark-0d93). Xid codes
are logged by the driver in `journalctl -k` (`NVRM: Xid (PCI:...): <code>, ...`) and
tracked as Prometheus counters by `scripts/spark-node-monitoring/gpu-xid-exporter.sh`
(`spark_gpu_xid_errors_total`, `spark_gpu_xid_last_seen_timestamp_seconds`). Check
current counts with `scripts/spark-health.sh` (`/check-spark-health` covers the rest
of Spark's health but not Xid detail).

## Xid 13 — Graphics SM Global Exception

A running shader or CUDA kernel caused a hardware exception on one of the GPU's
Streaming Multiprocessors (SMs). The faulting kernel is terminated; other kernels
running on different SMs can continue. Generally the more recoverable of the two —
contained to the specific kernel that faulted rather than the whole GPU engine.

## Xid 43 — GPU Stopped Processing

The GPU has a hardware watchdog timer that monitors whether submitted work is making
progress. When a CUDA kernel, copy engine, or other GPU operation runs longer than the
timeout period without completing, the watchdog fires and the driver attempts an
engine reset to recover it.

**Common causes:** infinite loops or stuck kernels, transient PCIe communication
glitches, thermal throttling pushing execution time past the timeout.

**Severity vs Xid 13:** broader impact — a hang of the whole GPU engine rather than one
SM's kernel — so operationally more serious even though it's usually recoverable via
reset. Can point to system-level issues (PCIe, thermal, driver) rather than just a bad
kernel. Xid 45 ("GPU has fallen off the bus") often follows a repeated 43→reset→43
cycle when recovery keeps failing.

## Known incident on Spark

[2026-08-28 vLLM outage postmortem](spark-vllm-xid13-postmortem.md): 91 Xid 13 events
fired within the same second across all 4 GPCs, followed 3 seconds later by 1 Xid 43 —
the driver-level consequence of the GPU resetting the faulting channel. vLLM's
`ExecStop` then ran cleanly, which is why the outage initially looked like a deliberate
stop rather than a hardware fault. As of 2026-09-02, no further Xid 13/43 events have
recurred since that incident (~113.9 hours and counting at last check).

## References

- [The Complete NVIDIA Xid Error Field Guide](https://www.abhik.ai/articles/nvidia-xid-errors)
- [Troubleshoot Xid errors in NVIDIA GPU-accelerated instances (AWS re:Post)](https://repost.aws/knowledge-center/ec2-linux-troubleshoot-xid-errors)
- [PowerEdge: Resolving Critical Xid Error with NVIDIA T4 GPU (Dell)](https://www.dell.com/support/kbdoc/en-us/000220148/poweredge-r7515-with-nvidia-t4-gpu-detected-critical-xid-error-and-gpu-stopped-processing)
- [GPU Health (Modal Docs)](https://modal.com/docs/guide/gpu-health)
