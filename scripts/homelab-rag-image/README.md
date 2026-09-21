# homelab-rag

HTTP wrapper around the homelab RAG pipeline (embed query -> pgvector
retrieve -> Nemotron synthesis with citation grounding), so gptel's
`homelab_rag` tool (omen's Doom Emacs config,
`~/Projects/dotfiles/doomemacs/doom/config.el`) gets one already-vetted
answer from a single HTTP call, instead of driving retrieval itself with
none of the guardrails documented in pydantic-agent's CLAUDE.md
(reasoning suppression, a hard cap on search calls, a tool-free fallback
when that cap is hit, citation-grounding instructions).

This is a self-contained reimplementation of the query side of
`pydantic-agent/examples/rag_homelab.py` - that project has no git remote
this cluster's build Job can reach, so this can't just clone and reuse it.
The indexing side (building/refreshing `doc_sections`) stays on omen via
that project's systemd timer (`rag-homelab-index.timer`); this service
only ever reads from the same `postgres-pgvector` instance, over
cluster-internal DNS rather than the tailnet (it runs in-cluster).

## API

- `GET /ask?q=<question>` -> `{"question", "answer", "retrieve_calls", "elapsed_s"}`
- `GET /health` -> `{"status": "ok"}`

The agent behind `/ask` also has a `reindex_docs` tool (2026-09-21) - a
question phrased as a reindex request (e.g. "reindex the docs") triggers a
real reindex. This pod has no filesystem access to the source corpus (only
omen does), so the tool doesn't reindex locally - it SSHes into omen with a
dedicated key that's restricted server-side (omen's `~/.ssh/authorized_keys`
forces `rebuild-rag-index.sh` regardless of what command is sent, via
`command="..."`), so a compromised pod can't use this key for anything else
on omen. There's no confirmation gate beyond the tool's own docstring -
this is a real, unauthenticated-beyond-the-tailnet mutation trigger, same
tradeoff as pydantic-agent's local `reindex_docs` tool it mirrors.

## Build + deploy

```bash
kubectl apply -f scripts/homelab-rag-image/build-job.yaml
# then let Flux reconcile manifests/homelab-rag/, or force it:
kubectl -n flux-system annotate kustomization homelab-rag reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

Needs `OPENAI_API_KEY`, `POSTGRES_PASSWORD`, and the omen-reindex SSH
material as a Secret in the `homelab-rag` namespace, created out-of-band
(not in git):

```bash
kubectl create secret generic homelab-rag-secrets -n homelab-rag \
  --from-literal=openai-api-key=<key> \
  --from-literal=postgres-password=<password from postgres-pgvector-password secret> \
  --from-file=omen-ssh-private-key=<path to the dedicated ed25519 private key> \
  --from-file=omen-ssh-known-hosts=<path to a known_hosts file pinning omen's actual host key>
```

The private key must correspond to a public key added to omen's
`~/.ssh/authorized_keys` with a `command=` restriction to
`/home/cb/Projects/pydantic-agent/scripts/rebuild-rag-index.sh` (plus
`restrict` to disable port/X11/agent forwarding and pty allocation) - never
add this key unrestricted. Generate the known_hosts entry with:
`ssh-keyscan -t ed25519 <omen tailnet IP> | sed 's/^[^ ]*/omen.homelab-rag.svc.cluster.local/'`
so it matches `OMEN_SSH_HOST` in `manifests/homelab-rag/deployment.yaml`,
not the scan target.

Reachable at `http://homelab-rag.taildd208.ts.net/ask?q=...` from any
tailnet device (including gptel on omen).
