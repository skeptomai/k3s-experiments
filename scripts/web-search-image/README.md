# web-search

Minimal HTTP proxy in front of `ddgs` (DuckDuckGo search, no API key needed) —
same library Open WebUI's own `web_search` tool uses. Exists so gptel's
`web_search` tool (omen's Doom Emacs config, `~/Projects/dotfiles/doomemacs/doom/config.el`)
has something to call **without installing anything on omen** — omen is
deliberately kept stateless, all actual compute runs on the cluster or spark.

## API

- `GET /search?q=<query>&max_results=<n, default 5, max 10>` → `{"query": ..., "results": [{"title", "url", "snippet"}, ...]}`
- `GET /health` → `{"status": "ok"}`

## Build + deploy

```bash
kubectl apply -f scripts/web-search-image/build-job.yaml   # builds + pushes to zot-local
# then let Flux reconcile manifests/web-search/, or force it:
kubectl -n flux-system annotate kustomization web-search reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

Reachable at `http://web-search.taildd208.ts.net/search?q=...` from any tailnet device.
