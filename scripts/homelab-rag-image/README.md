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

## Build + deploy

```bash
kubectl apply -f scripts/homelab-rag-image/build-job.yaml
# then let Flux reconcile manifests/homelab-rag/, or force it:
kubectl -n flux-system annotate kustomization homelab-rag reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

Needs `OPENAI_API_KEY` and `POSTGRES_PASSWORD` as a Secret in the
`homelab-rag` namespace, created out-of-band (not in git):

```bash
kubectl create secret generic homelab-rag-secrets -n homelab-rag \
  --from-literal=openai-api-key=<key> \
  --from-literal=postgres-password=<password from postgres-pgvector-password secret>
```

Reachable at `http://homelab-rag.taildd208.ts.net/ask?q=...` from any
tailnet device (including gptel on omen).
