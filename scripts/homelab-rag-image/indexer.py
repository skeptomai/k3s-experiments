"""In-cluster reindexing for the homelab-rag service.

Ported from pydantic-agent's examples/rag_homelab.py, generalized: instead
of reading source files directly off a laptop's filesystem (omen), this
clones/pulls each source's own git repo into a PVC mounted at
SOURCES_ROOT, then runs the same content-hash-incremental chunk/embed
pipeline against those local clones. This removes the one dependency the
first version of this feature had - omen being up and reachable - which
matters because omen is a laptop, not always on, and not the only machine
work happens from (see pydantic-agent's CLAUDE.md).

Repo scope is deliberately NOT "every ~/Projects dir" (unlike the local
rag_homelab.py's generic PROJECT_ROOTS pass) - cloning ~40 repos including
things like a full Linux kernel checkout into a cluster PVC is not
reasonable. GIT_REPOS below is an explicit, reviewed whitelist instead.

Source labels are kept identical in format to rag_homelab.py's (e.g.
"k3s-experiments/docs/foo.md", "<repo>/CLAUDE.md") on purpose: this
service and the local omen-based indexer write to the same `doc_sections`
table, and matching labels mean either indexer can freshen the same rows
without creating duplicates under two different label spellings for the
same logical document.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

import asyncpg
import pydantic_core
from openai import AsyncOpenAI

SOURCES_ROOT = Path(os.getenv("SOURCES_ROOT", "/data/sources"))
GIT_KEYS_DIR = Path(os.getenv("GIT_KEYS_DIR", "/etc/git-keys"))
KNOWN_HOSTS = GIT_KEYS_DIR / "known_hosts"
MANIFEST_PATH = SOURCES_ROOT / ".rag_manifest.json"

MAX_CHUNK_CHARS = 6000
EMBEDDING_MODEL = "text-embedding-3-small"

FORGEJO_HOST = os.getenv("FORGEJO_SSH_HOST", "git-repos.homelab-rag.svc.cluster.local")


def _forgejo(repo: str) -> str:
    return f"ssh://git@{FORGEJO_HOST}:2222/skeptomai/{repo}.git"


# Each entry:
#   name: also the clone directory name under SOURCES_ROOT
#   url: clone URL (https for public repos - no credential needed;
#        ssh for private repos - paired with `key`)
#   key: deploy key filename under GIT_KEYS_DIR, or None for public repos
#   overview: index this repo's top-level CLAUDE.md/README.md, same
#             convention rag_homelab.py's PROJECT_ROOTS pass uses
#             (label f"{name}/{filename}")
#   deep: list of (subpath-within-repo, glob, label) for a full docs pass,
#         same shape as rag_homelab.py's SOURCES entries
GIT_REPOS = [
    # --- public GitHub, no credential needed ---
    {
        "name": "k3s-experiments",
        "url": "https://github.com/skeptomai/k3s-experiments.git",
        "key": None,
        "overview": True,
        "deep": [
            ("docs", "**/*.md", "k3s-experiments/docs"),
            ("experiments", "**/*.md", "k3s-experiments/experiments"),
            ("manifests", "**/*.yaml", "k3s-experiments/manifests"),
            ("clusters", "**/*.yaml", "k3s-experiments/clusters"),
        ],
    },
    {
        "name": "pelagos",
        "url": "https://github.com/pelagos-containers/pelagos.git",
        "key": None,
        "overview": True,
        "deep": [("docs", "**/*.md", "pelagos/docs")],
    },
    {"name": "cairn", "url": "https://github.com/skeptomai/cairn.git", "key": None, "overview": True, "deep": []},
    {
        "name": "datacenter-curriculum",
        "url": "https://github.com/skeptomai/datacenter-curriculum.git",
        "key": None,
        "overview": True,
        "deep": [],
    },
    {"name": "gruesome", "url": "https://github.com/skeptomai/gruesome.git", "key": None, "overview": True, "deep": []},
    {
        "name": "living-hinge-generator",
        "url": "https://github.com/skeptomai/living-hinge-generator.git",
        "key": None,
        "overview": True,
        "deep": [],
    },
    {
        "name": "omarchy-emacs-themer",
        "url": "https://github.com/skeptomai/omarchy-emacs-themer.git",
        "key": None,
        "overview": True,
        "deep": [],
    },
    {
        "name": "omarchy-hibernate",
        "url": "https://github.com/skeptomai/omarchy-hibernate.git",
        "key": None,
        "overview": True,
        "deep": [],
    },
    {
        "name": "omarchy-themes",
        "url": "https://github.com/skeptomai/omarchy-themes.git",
        "key": None,
        "overview": True,
        "deep": [],
    },
    {
        "name": "pelagos-mac",
        "url": "https://github.com/pelagos-containers/pelagos-mac.git",
        "key": None,
        "overview": True,
        "deep": [],
    },
    {
        "name": "pelagos-tui",
        "url": "https://github.com/skeptomai/pelagos-tui.git",
        "key": None,
        "overview": True,
        "deep": [],
    },
    {
        "name": "pelagos-ui",
        "url": "https://github.com/pelagos-containers/pelagos-ui.git",
        "key": None,
        "overview": True,
        "deep": [],
    },
    # --- private GitHub, deploy key required ---
    {
        "name": "dotfiles",
        "url": "git@github.com:skeptomai/dotfiles.git",
        "key": "github-dotfiles",
        "overview": True,
        "deep": [("doomemacs/doom", "*.el", "dotfiles/doomemacs/doom")],
    },
    {
        "name": "orgfiles",
        "url": "git@github.com:skeptomai/orgfiles.git",
        "key": "github-orgfiles",
        "overview": False,
        "deep": [(".", "**/*.md", "orgfiles"), (".", "**/*.org", "orgfiles")],
    },
    {
        "name": "hibernate_debugging",
        "url": "git@github.com:skeptomai/hibernate_debugging.git",
        "key": "github-hibernate_debugging",
        "overview": True,
        "deep": [],
    },
    {
        "name": "home-monitoring",
        "url": "git@github.com:skeptomai/home-monitoring.git",
        "key": "github-home-monitoring",
        "overview": True,
        "deep": [(".", "**/*.md", "home-monitoring")],
    },
    # --- private Forgejo, deploy key required (reached via the
    # git-repos egress ExternalName Service, same tailnet-egress pattern
    # already used for the Spark) ---
    {
        "name": "pydantic-agent",
        "url": _forgejo("pydantic-agent"),
        "key": "forgejo-pydantic-agent",
        "overview": True,
        "deep": [
            ("src", "**/*.py", "pydantic-agent/src"),
            ("examples", "**/*.py", "pydantic-agent/examples"),
        ],
    },
    {
        "name": "claude-skills-mirror",
        "url": _forgejo("claude-skills-mirror"),
        "key": "forgejo-claude-skills-mirror",
        "overview": True,
        "deep": [("skills", "*/SKILL.md", "skills")],
    },
    {
        "name": "backup-kit",
        "url": _forgejo("backup-kit"),
        "key": "forgejo-backup-kit",
        "overview": False,
        "deep": [(".", "*.md", "backup-kit")],
    },
    {
        "name": "agent-coordinator",
        "url": _forgejo("agent-coordinator"),
        "key": "forgejo-agent-coordinator",
        "overview": True,
        "deep": [],
    },
]

OVERVIEW_FILENAMES = ("CLAUDE.md", "README.md")


def _git_env(repo: dict) -> dict:
    env = os.environ.copy()
    if repo["key"]:
        key_path = GIT_KEYS_DIR / repo["key"]
        env["GIT_SSH_COMMAND"] = (
            f"ssh -i {key_path} -o IdentitiesOnly=yes "
            f"-o UserKnownHostsFile={KNOWN_HOSTS} -o StrictHostKeyChecking=yes "
            f"-o ConnectTimeout=10 -o BatchMode=yes"
        )
    return env


def clone_or_update(repo: dict) -> str:
    """Clone if missing, else fetch+reset to the remote's default branch.
    Runs git as a blocking subprocess - called via asyncio.to_thread.

    Full history, NOT --depth 1: the freshness guard (see
    _git_commit_time_from_clone below) needs `git log -1 -- <path>` to
    return the commit that actually last touched a file, not just "the
    single commit a shallow clone happens to have" - a shallow clone would
    report every unchanged file as freshly-committed (the tip commit's
    date), which could make this indexer's stamps look artificially newer
    than a correct local reindex's and wrongly let it win a freshness
    comparison it shouldn't."""
    dest = SOURCES_ROOT / repo["name"]
    env = _git_env(repo)
    if not dest.exists():
        subprocess.run(
            ["git", "clone", "--quiet", repo["url"], str(dest)],
            env=env, check=True, capture_output=True, text=True,
        )
        return "cloned"
    subprocess.run(
        ["git", "-C", str(dest), "fetch", "--quiet", "origin"],
        env=env, check=True, capture_output=True, text=True,
    )
    head = subprocess.run(
        ["git", "-C", str(dest), "rev-parse", "origin/HEAD"],
        env=env, capture_output=True, text=True,
    )
    ref = head.stdout.strip() if head.returncode == 0 else "FETCH_HEAD"
    subprocess.run(
        ["git", "-C", str(dest), "reset", "--quiet", "--hard", ref],
        env=env, check=True, capture_output=True, text=True,
    )
    return "updated"


def _chunk_by_char_limit(title: str, content: str, source_label: str) -> list[dict]:
    content = content.strip()
    if not content:
        return []
    chunks = []
    for i in range(0, len(content), MAX_CHUNK_CHARS):
        piece = content[i : i + MAX_CHUNK_CHARS]
        suffix = f" (part {i // MAX_CHUNK_CHARS + 1})" if i > 0 else ""
        chunks.append({"title": title + suffix, "content": piece, "source": source_label})
    return chunks


def chunk_markdown(path: Path, source_label: str) -> list[dict]:
    text = path.read_text(errors="ignore")
    lines = text.splitlines()
    chunks: list[dict] = []
    title = path.name
    body: list[str] = []

    def flush() -> None:
        chunks.extend(_chunk_by_char_limit(title, "\n".join(body), source_label))

    for line in lines:
        m = re.match(r"^(#{1,2})\s+(.*)", line)
        if m:
            flush()
            title = m.group(2).strip()
            body = []
        else:
            body.append(line)
    flush()
    return chunks


def chunk_whole_file(path: Path, source_label: str) -> list[dict]:
    return _chunk_by_char_limit(path.name, path.read_text(errors="ignore"), source_label)


def chunk_file(path: Path, source_label: str) -> list[dict]:
    if path.suffix == ".md":
        return chunk_markdown(path, source_label)
    return chunk_whole_file(path, source_label)


def iter_source_files() -> list[tuple[Path, str]]:
    files: list[tuple[Path, str]] = []
    for repo in GIT_REPOS:
        repo_root = SOURCES_ROOT / repo["name"]
        for subpath, pattern, label in repo["deep"]:
            root = repo_root if subpath == "." else repo_root / subpath
            if not root.exists():
                continue
            for p in sorted(root.glob(pattern)):
                if p.is_file():
                    files.append((p, f"{label}/{p.relative_to(root)}"))
        if repo["overview"]:
            for filename in OVERVIEW_FILENAMES:
                overview = repo_root / filename
                if overview.is_file():
                    files.append((overview, f"{repo['name']}/{filename}"))
    return files


def _file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _git_commit_time(path: Path) -> str:
    """ISO8601 timestamp of the commit that actually last touched this
    file, per the same freshness-guard logic as pydantic-agent's local
    rag_homelab.py - see that function's docstring for why "differs from
    my manifest" isn't the same as "is actually newer". Clones here are
    always clean (reset --hard to the remote tip, never locally edited),
    so there's no "dirty means now" case to handle, unlike the local
    indexer's live working directory."""
    log = subprocess.run(
        ["git", "-C", str(path.parent), "log", "-1", "--format=%cI", "--", path.name],
        capture_output=True, text=True,
    )
    if log.returncode == 0 and log.stdout.strip():
        return log.stdout.strip()
    return datetime.now(timezone.utc).isoformat()


def _manifest_meta() -> dict:
    return {"embedding_model": EMBEDDING_MODEL, "max_chunk_chars": MAX_CHUNK_CHARS}


def load_manifest() -> dict:
    if not MANIFEST_PATH.exists():
        return {"meta": _manifest_meta(), "files": {}}
    manifest = json.loads(MANIFEST_PATH.read_text())
    if manifest.get("meta") != _manifest_meta():
        return {"meta": _manifest_meta(), "files": {}}
    return manifest


def save_manifest(manifest: dict) -> None:
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=True))


async def insert_doc_section(
    sem: asyncio.Semaphore, openai: AsyncOpenAI, pool: asyncpg.Pool, chunk: dict, source_updated_at: str | None
) -> None:
    async with sem:
        embedding = await openai.embeddings.create(
            input=f"{chunk['title']}\n\n{chunk['content']}", model=EMBEDDING_MODEL
        )
        embedding_json = pydantic_core.to_json(embedding.data[0].embedding).decode()
        await pool.execute(
            "INSERT INTO doc_sections (source, title, content, embedding, source_updated_at) "
            "VALUES ($1, $2, $3, $4, $5)",
            chunk["source"], chunk["title"], chunk["content"], embedding_json,
            datetime.fromisoformat(source_updated_at) if source_updated_at else None,
        )


async def reindex(pool: asyncpg.Pool) -> str:
    """Clone/update every repo in GIT_REPOS, then incrementally
    chunk/embed whatever changed since the last run. Returns a short
    human-readable summary."""
    SOURCES_ROOT.mkdir(parents=True, exist_ok=True)
    t0 = time.monotonic()

    # Idempotent - safe to run every call. This service doesn't own table
    # creation (rag_homelab.py's build_search_db() does, and already ran
    # against the shared DB), but defensively ensures the freshness-guard
    # column exists regardless of which indexer initializes the table.
    await pool.execute("ALTER TABLE doc_sections ADD COLUMN IF NOT EXISTS source_updated_at timestamptz")

    clone_results = await asyncio.gather(
        *(asyncio.to_thread(clone_or_update, repo) for repo in GIT_REPOS),
        return_exceptions=True,
    )
    failures = [
        f"{repo['name']}: {result}"
        for repo, result in zip(GIT_REPOS, clone_results)
        if isinstance(result, Exception)
    ]
    t1 = time.monotonic()

    files = iter_source_files()
    manifest = load_manifest()
    prior_files = manifest["files"]

    current_labels = {label for _, label in files}
    hashes = {label: _file_hash(path) for path, label in files}
    changed = [
        (path, label) for path, label in files
        if prior_files.get(label, {}).get("hash") != hashes[label]
    ]
    removed_labels = set(prior_files) - current_labels
    freshness = {label: _git_commit_time(path) for path, label in changed}

    openai = AsyncOpenAI()
    to_write: list[tuple] = []
    skipped_stale: list[str] = []
    if changed:
        # Freshness guard (mirrors pydantic-agent's local rag_homelab.py):
        # "differs from my manifest" only means this clone's content
        # changed since I last looked, not that it's newer than what's
        # already in the DB - don't let a clone that happens to be behind
        # (e.g. this pod hasn't reindexed in a while and someone force-
        # pushed a revert upstream) clobber fresher content with older.
        existing = {
            row["source"]: row["max"]
            for row in await pool.fetch(
                "SELECT source, max(source_updated_at) FROM doc_sections "
                "WHERE source = ANY($1::text[]) GROUP BY source",
                [label for _, label in changed],
            )
        }
        for path, label in changed:
            current = existing.get(label)
            if current is not None and datetime.fromisoformat(freshness[label]) < current:
                skipped_stale.append(label)
            else:
                to_write.append((path, label))

    all_chunks: list[dict] = []
    for path, label in to_write:
        all_chunks.extend(chunk_file(path, label))

    if to_write or removed_labels:
        stale_labels = removed_labels | {label for _, label in to_write}
        await pool.execute("DELETE FROM doc_sections WHERE source = ANY($1::text[])", list(stale_labels))
        sem = asyncio.Semaphore(10)
        await asyncio.gather(
            *(insert_doc_section(sem, openai, pool, c, freshness.get(c["source"])) for c in all_chunks)
        )

    written_labels = {label for _, label in to_write}
    for label in removed_labels:
        del manifest["files"][label]
    for _, label in changed:
        if label in written_labels:
            chunk_count = sum(1 for c in all_chunks if c["source"] == label)
        else:
            chunk_count = prior_files.get(label, {}).get("chunk_count", 0)
        manifest["files"][label] = {"hash": hashes[label], "chunk_count": chunk_count}
    save_manifest(manifest)

    elapsed = time.monotonic() - t0
    summary = (
        f"Cloned/updated {len(GIT_REPOS)} repos in {t1 - t0:.1f}s. "
        f"{len(files)} source files, {len(changed)} changed/new, {len(removed_labels)} removed, "
        f"{len(all_chunks)} chunks (re)embedded. Total {elapsed:.1f}s."
    )
    if skipped_stale:
        summary += f" Skipped {len(skipped_stale)} file(s) as older than what's already indexed."
    if failures:
        summary += f" CLONE FAILURES (stale data for these repos): {'; '.join(failures)}"
    return summary
