# Experiment 28 — SPIRE TPM DevID: SRK Reuse Patch

On ipc9, the Infineon SLB9672 TPM makes `CreatePrimary` take ~24 seconds per call, and the unpatched spire-agent calls it three times per attestation — inflating node attestation from an expected few seconds to over 75 seconds. This experiment builds a patched `spire-agent` from the `skeptomai/spire` fork (branch `tpmdevid-srk-reuse`) that reuses the Storage Root Key handle across the attestation flow instead of recreating it, and validates the fix with interleaved controlled trials captured via bpftrace on ipc9.

## Files

| File | Purpose |
|------|---------|
| `build-job.yaml` | Kubernetes Job that clones the patched spire fork, builds `spire-agent`, and pushes the image to the local registry at `192.168.89.2:5004/spire-agent:patched` |
| `Remfile` | Pelagos build descriptor: layers the compiled binary over `ghcr.io/spiffe/spire-agent:1.9.6` |
| `deploy-test.yaml` | DaemonSet pinned to ipc9 running the patched image alongside the production SPIRE DaemonSet, using a separate socket path to avoid collision |
| `test-patched.yaml` | Trial DaemonSet for the patched agent — used by `run-trial.sh` for controlled timing measurements |
| `test-unpatched.yaml` | Trial DaemonSet for the stock `ghcr.io/spiffe/spire-agent:1.9.6` — baseline for timing comparison |
| `run-all-trials.sh` | Orchestrates a 4-trial interleaved sequence (unpatched/patched/unpatched/patched), isolating ipc9 via taint + nodeAffinity patch, then restores the node |
| `run-trial.sh` | Runs a single trial: deploys a DaemonSet, starts bpftrace on ipc9, waits for attestation success, collects timing, tears down |
| `trial-results/` | Raw bpftrace output (`.bt`) and structured logs (`.log`) for 8 trials |

## Build

Build the patched image on the cluster before running trials:

```
kubectl apply -f experiments/28-spire-tpmdevid-patch/build-job.yaml
```

Watch build progress: `kubectl logs -f job/spire-agent-build -c clone-and-build` then `-c build-and-push`. The image lands at `192.168.89.2:5004/spire-agent:patched` on success.

## Running Trials

The trial scripts require the bpftrace script at `scripts/bpftrace-spire-tpm-stall.bt`. Run the full interleaved sequence from omen:

```
bash experiments/28-spire-tpmdevid-patch/run-all-trials.sh
```

This taints ipc9, excludes it from the production SPIRE DaemonSet, runs 4 trials with 60-second cooldowns, then restores the node. Results land in `trial-results/`.

## Observe

Check attestation times from the trial logs:

```
grep "Node attestation was successful\|Starting node attestation" experiments/28-spire-tpmdevid-patch/trial-results/*.log
```

Results from the collected trials:

| Trial | Variant | Attestation time |
|-------|---------|-----------------|
| 1 | unpatched | ~77s |
| 2 | patched | ~28s |
| 3 | unpatched | ~76s |
| 4 | patched | ~28s |
| 7 | unpatched | ~77s |
| 8 | patched | ~28s |

The bpftrace output in `.bt` files shows the unpatched agent making three separate `CreatePrimary` calls — each preceded by a ~24-second TPM write stall — while the patched agent makes one, cutting total attestation time by ~65%.

To smoke-test the patched image in-cluster without the trial harness: `kubectl apply -f experiments/28-spire-tpmdevid-patch/deploy-test.yaml` and watch `kubectl logs -n spire -l app=spire-agent-patched -f`.

## Teardown

```
kubectl delete -f experiments/28-spire-tpmdevid-patch/deploy-test.yaml
```

The trial DaemonSets are deleted automatically by `run-all-trials.sh`. The build Job self-deletes after 3600 seconds (`ttlSecondsAfterFinished`). If the node was left tainted after an interrupted trial run: `kubectl taint node ipc9 spire-test=true:NoSchedule-`
