---
name: check-cluster-health
description: Run the cluster health check script on ipc4 and display results
---

Run `scripts/check-cluster-health.sh` on ipc4 via SSH and display the output verbatim.
Do not add commentary, preamble, or analysis — just run and show.
If any FAIL or WARN lines appear, after the output list them as a brief bullet summary
and ask the user if they want to investigate.

```bash
ssh -o ControlMaster=no cb@ipc4.taildd208.ts.net "bash -s" < /home/cb/Projects/k3s-experiments/scripts/check-cluster-health.sh
```
