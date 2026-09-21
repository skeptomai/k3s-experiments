# homelab-rag

HTTP wrapper around the homelab RAG pipeline (embed query -> pgvector
retrieve -> Nemotron synthesis with citation grounding), so gptel's
`homelab_rag` tool (omen's Doom Emacs config,
`~/Projects/dotfiles/doomemacs/doom/config.el`) gets one already-vetted
answer from a single HTTP call, instead of driving retrieval itself with
none of the guardrails documented in pydantic-agent's CLAUDE.md
(reasoning suppression, a hard cap on search calls, a tool-free fallback
when that cap is hit, citation-grounding instructions).

The query path (`app.py`) is a self-contained reimplementation of the
query side of `pydantic-agent/examples/rag_homelab.py` - keep the two in
sync by hand if that logic changes. The **indexing** side
(`indexer.py`, added 2026-09-21) is this service's own thing, not a
reimplementation of anything - it clones/pulls each documented source's
own git repo directly into a PVC (`homelab-rag-sources`) and runs the same
content-hash-incremental chunk/embed pipeline locally against those
clones. This deliberately replaced an earlier version that SSHed into
omen to run the reindex there: that made omen a hard dependency, and omen
is a laptop that isn't always on and isn't the only machine work happens
from. Nothing in this service talks to omen anymore.

`indexer.py`'s `GIT_REPOS` list is an explicit, reviewed whitelist - NOT
"every project under ~/Projects" (that's ~40+ dirs, including things like
a full Linux kernel checkout; cloning all of that into a cluster PVC isn't
reasonable). See that module's docstring for the reasoning behind which
repos are in scope. Both the local (`rag_homelab.py`, still uses the
`PROJECT_ROOTS` broad generic pass) and in-cluster (`indexer.py`,
whitelist-only) indexers write to the same `doc_sections` table using
identical source-label conventions, so either can freshen the same rows
without creating duplicates - they're independent, redundant paths to the
same store, not two competing sources of truth.

## API

- `GET /ask?q=<question>` -> `{"question", "answer", "retrieve_calls", "elapsed_s"}`
- `GET /health` -> `{"status": "ok"}`

The agent behind `/ask` also has a `reindex_docs` tool - a question
phrased as a reindex request (e.g. "reindex the docs") triggers
`indexer.reindex()` in-process: clone/pull every repo in `GIT_REPOS`, then
incrementally chunk/embed whatever changed since the last run (tracked in
`.rag_manifest.json` on the PVC, so a restart doesn't lose incrementality).
There's no confirmation gate beyond the tool's own docstring - this is a
real, unauthenticated-beyond-the-tailnet mutation trigger, same tradeoff
documented in pydantic-agent's CLAUDE.md for the local `reindex_docs` tool
this was originally mirroring.

## Build + deploy

```bash
kubectl apply -f manifests/homelab-rag/sources-pvc.yaml   # first time only
kubectl apply -f scripts/homelab-rag-image/build-job.yaml
# then let Flux reconcile manifests/homelab-rag/, or force it:
kubectl -n flux-system annotate kustomization homelab-rag reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

Needs `OPENAI_API_KEY`, `POSTGRES_PASSWORD`, and one read-only deploy key
per **private** repo in `indexer.py`'s `GIT_REPOS` (public repos there
clone anonymously over HTTPS - no credential needed), plus a
`known-hosts` file pinning github.com's and Forgejo's real host keys, all
as a Secret in the `homelab-rag` namespace, created out-of-band (not in
git):

```bash
kubectl create secret generic homelab-rag-secrets -n homelab-rag \
  --from-literal=openai-api-key=<key> \
  --from-literal=postgres-password=<password from postgres-pgvector-password secret> \
  --from-file=known-hosts=<known_hosts pinning github.com and git-repos.homelab-rag.svc.cluster.local:2222> \
  --from-file=github-dotfiles=<private key> \
  --from-file=github-orgfiles=<private key> \
  --from-file=github-hibernate_debugging=<private key> \
  --from-file=github-home-monitoring=<private key> \
  --from-file=forgejo-pydantic-agent=<private key> \
  --from-file=forgejo-claude-skills-mirror=<private key> \
  --from-file=forgejo-backup-kit=<private key> \
  --from-file=forgejo-agent-coordinator=<private key>
```

Each private key's file name must exactly match its `key` field in
`indexer.py`'s `GIT_REPOS` (that's how the pod finds the right key for
each repo). Each corresponding public key must be registered as a
**read-only** deploy key on that specific repo (GitHub: repo Settings ->
Deploy keys; Forgejo: same concept via its API/UI) - verify read-only by
attempting a push with it and confirming the server refuses, don't just
trust the checkbox. GitHub repos are cloned over SSH (`git@github.com`,
reachable directly - no tailnet egress needed, confirmed with a throwaway
pod testing outbound port 22); Forgejo repos are cloned via
`git-repos.homelab-rag.svc.cluster.local:2222`, reachable only through the
`git-repos-egress` ExternalName Service (`manifests/homelab-rag/git-repos-egress.yaml`,
the same Tailscale-operator egress pattern as `spark-egress.yaml`).

Reachable at `http://homelab-rag.taildd208.ts.net/ask?q=...` from any
tailnet device (including gptel on omen).
