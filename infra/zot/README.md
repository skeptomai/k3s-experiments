# Zot registry stack (runs on nazgul)

Five Zot instances behind one hand-run docker-compose on **nazgul**
(`/mnt/primary_storage/zot/`). Four are pull-through caches (one per upstream),
the fifth is our own writeable registry. This directory is the **source of
truth** — the files here are copied verbatim to nazgul; edit here, then deploy.

> Not Flux-managed (Flux only manages `manifests/`). nazgul containers are run
> directly via docker-compose, like the rest of the home-monitoring stack.

## Layout

| Instance     | Host port | Upstream / role            | Data dir (on nazgul)          |
|--------------|-----------|----------------------------|-------------------------------|
| `zot-docker` | 5000      | `registry-1.docker.io`     | `/mnt/primary_storage/zot/data`        |
| `zot-k8s`    | 5001      | `registry.k8s.io`          | `/mnt/primary_storage/zot/data-k8s`    |
| `zot-ghcr`   | 5002      | `ghcr.io`                  | `/mnt/primary_storage/zot/data-ghcr`   |
| `zot-ecr`    | 5003      | `public.ecr.aws`           | `/mnt/primary_storage/zot/data-ecr`    |
| `zot-local`  | 5004      | **writeable** (no sync)    | `/mnt/primary_storage/zot/data-local`  |

Each instance listens on container port 5000 and is mapped to its host port.
Each gets its own single-file config mounted at `/etc/zot/config.json`.

## Why one instance per upstream (not one shared port)

Pelagos strips the registry host when it rewrites a reference to a mirror
endpoint, so a single shared port can't tell which upstream a *flattened* repo
(`pause` vs `library/alpine`) belongs to — it forces Zot to fan out across all
configured upstreams per cache-miss (~20s latency + auth noise). One upstream
per port routes each repo to exactly one origin and fails fast / fetches
reliably. The caches use `onDemand` sync; `zot-local` has no `sync` extension,
so it's a normal read-write OCI registry.

## How the cluster reaches these

Node-side config lives in [`../../config/pelagos-registries.toml`](../../config/pelagos-registries.toml)
(deployed to `/etc/pelagos/registries.toml` on every node by
`scripts/install-pelagos.sh`). It maps each upstream to its cache port, and adds
a **self-referential** entry for the writeable registry so CRI pulls go over
HTTP (k8s pod specs can't pass `--insecure`; Pelagos infers insecure from the
`http://` scheme):

```toml
"192.168.89.2:5004" = ["http://192.168.89.2:5004"]
```

## Using the writeable registry (`:5004`)

Build/push from any cluster node (pelagos is installed there):

```
sudo pelagos image tag <src> 192.168.89.2:5004/<repo>:<tag>   # or: pelagos build -t ...
sudo pelagos image push --insecure 192.168.89.2:5004/<repo>:<tag>
```

Then reference `192.168.89.2:5004/<repo>:<tag>` in any manifest — no
`imagePullSecrets`, no cluster-side flags. (`--insecure` is only needed by the
*pusher*.) Repo path, not host, is Zot's storage key, so push-host and pull-host
addresses can differ as long as both hit this Zot.

Inspect:

```
curl http://192.168.89.2:5004/v2/_catalog
curl http://192.168.89.2:5004/v2/<repo>/tags/list
```

## Deploy / update

From omen (the repo is the source of truth):

```
bash infra/zot/deploy.sh
```

This rsyncs `docker-compose.yml` + `config/` to nazgul and runs
`docker compose up -d`. Data dirs are created on first run and persist across
restarts. Pelagos reads `registries.toml` fresh per pull, so no node restart is
needed after changing cache routing — but re-run `scripts/install-pelagos.sh`
(or re-copy the file) to push registries.toml changes to the nodes.

## Notes / gotchas

- **Off-LAN access:** reach nazgul via the tailnet `nazgul.taildd208.ts.net`;
  the `192.168.89.2` LAN IP only works on the home network.
- **onDemand caches only grow on first pull.** A cold image takes the upstream
  sync time once, then serves locally.
- **Multi-arch by-digest mirror bug:** some multi-arch pulls via the *cache*
  mirrors fall back to origin (don't cache) due to pelagos#407. Pulls still
  succeed. Does not affect `zot-local` (direct push/pull, no mirror rewrite of
  child manifests).
- Open / no auth on all five — relies on LAN + tailnet trust.
