#!/usr/bin/env python3
"""HTTP wrapper around the homelab RAG pipeline (embed -> pgvector retrieve
-> Nemotron synthesis), so gptel (or anything else) can get one already-
vetted answer from a single HTTP call instead of driving the tool-calling
loop itself.

The query path (retrieve/answer_question below) is a self-contained
reimplementation of pydantic-agent's examples/rag_homelab.py query path -
keep it in sync by hand if that logic changes there. The indexing side is
NOT a reimplementation of anything on omen anymore (see indexer.py and the
2026-09-21 note below) - it's this service's own thing now, omen plays no
part in it.

Deliberately exposes exactly one coarse-grained endpoint (`/ask`), not the
raw retrieve step - a caller's own tool-calling loop (gptel's included) has
none of the guardrails below, and exposing raw retrieval would risk
reproducing the exact overquerying bug this project's history warns about.

As of 2026-09-21 the agent behind `/ask` also has a `reindex_docs` tool, so
a natural-language request like "reindex the docs" can trigger a real
reindex. Originally (same day) this SSHed into omen to run the reindex
there, since this pod had no filesystem access to the source corpus - but
that made omen a hard dependency (a laptop that isn't always on and isn't
the only machine work happens from), so it was replaced with a real
in-cluster pipeline: indexer.py clones/pulls each source's own git repo
into a PVC (see GIT_REPOS there for the exact, deliberately-scoped repo
list - NOT "every project", see its module docstring for why) and runs
the same content-hash-incremental chunk/embed logic locally against those
clones. omen is no longer touched by this at all. There is no confirmation
gate here beyond the tool's docstring - phrasing a question suggestively
is enough to trigger it, same tradeoff documented in pydantic-agent's
CLAUDE.md for the local `reindex_docs` tool this was originally mirroring
(that one still exists, unchanged, for ad-hoc local use).

API:
  GET /ask?q=<question>  -> {"question", "answer", "retrieve_calls", "elapsed_s"}
  GET /health            -> {"status": "ok"}
"""
import asyncio
import json
import os
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import asyncpg
import indexer
import pydantic_core
from openai import AsyncOpenAI
from pydantic_ai import Agent, RunContext
from pydantic_ai.exceptions import UsageLimitExceeded
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.usage import UsageLimits

# Reached via the Tailscale operator's egress pattern (an ExternalName
# Service annotated tailscale.com/tailnet-fqdn, see
# manifests/homelab-rag/spark-egress.yaml) - a plain cluster pod has no
# outbound tailnet route to a tailnet-only host otherwise (confirmed: DNS
# resolution for the tailnet hostname fails outright without this).
VLLM_BASE_URL = os.getenv("VLLM_BASE_URL", "http://spark-0d93.homelab-rag.svc.cluster.local:8000/v1")
MODEL_NAME = os.getenv("MODEL_NAME", "nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4")
VLLM_API_KEY = os.getenv("VLLM_API_KEY", "not-needed")

# Cluster-internal DNS, not the tailnet hostname - this service runs in the
# same cluster as postgres-pgvector, so it can skip the tailnet hop
# entirely (the Service's Tailscale exposure is for reaching it from
# outside the cluster, e.g. from omen's own rebuild-rag-index.sh).
PG_HOST = os.getenv("PG_HOST", "postgres-pgvector.postgres-pgvector.svc.cluster.local")
PG_PORT = int(os.getenv("PG_PORT", "5432"))
PG_USER = os.getenv("PG_USER", "postgres")
PG_PASSWORD = os.environ["POSTGRES_PASSWORD"]
PG_DATABASE = "homelab_docs"

RETRIEVE_CALL_LIMIT = 3  # see pydantic-agent CLAUDE.md - a hard framework
# cap, not a prompt instruction, which this model ignores under uncertainty.


@dataclass
class Deps:
    openai: AsyncOpenAI
    pool: asyncpg.Pool
    collected: list[str] = field(default_factory=list)
    retrieve_calls: int = 0


def _settings(max_tokens: int = 1500) -> dict:
    return {
        "extra_body": {"chat_template_kwargs": {"enable_thinking": False}},
        "max_tokens": max_tokens,
    }


def _model() -> OpenAIChatModel:
    return OpenAIChatModel(
        MODEL_NAME,
        provider=OpenAIProvider(base_url=VLLM_BASE_URL, api_key=VLLM_API_KEY),
        settings=_settings(),
    )


def build_agents() -> tuple[Agent, Agent]:
    """Fresh Agent instances per call, not module-level singletons.

    Each HTTP request runs under its own asyncio.run() call (see do_GET -
    ThreadingHTTPServer, no shared event loop across requests). A
    module-level Agent's internal async HTTP client (via OpenAIProvider)
    gets bound to whichever event loop first uses it, and crashes with
    "Event loop is closed" the first time a *different* request's loop
    tries to reuse it - confirmed directly: a reindex request that worked
    once server-side then failed instantly and reproducibly on every
    subsequent call, with agent/conclude_agent built once at import time.
    Constructing them fresh here (cheap - no network I/O until .run() is
    actually awaited) avoids any state crossing between event loops."""
    agent = Agent(
        _model(),
        deps_type=Deps,
        instructions=(
            "You answer questions about Christopher's homelab (k3s cluster, "
            "the DGX Spark, Claude Code skills, and his active projects) using "
            "the retrieved documentation. For every factual claim, cite the "
            "doc it came from in square brackets right after the claim. If "
            "you state something not supported by any retrieved doc, mark it "
            "'[not in retrieved docs]' instead of a citation."
        ),
    )
    conclude_agent = Agent(
        _model(),
        instructions=(
            "You answer questions about Christopher's homelab using the "
            "documentation excerpts already retrieved below - you have no "
            "search tool, so answer from what's given, or say what's missing. "
            "Cite the doc each claim came from in square brackets, or mark "
            "'[not in retrieved docs]' if it isn't supported by any of them."
        ),
    )
    agent.tool(retrieve)
    agent.tool(reindex_docs)
    return agent, conclude_agent


async def retrieve(context: RunContext[Deps], search_query: str) -> str:
    """Retrieve homelab documentation sections based on a search query."""
    context.deps.retrieve_calls += 1
    embedding = await context.deps.openai.embeddings.create(
        input=search_query, model="text-embedding-3-small"
    )
    embedding_json = pydantic_core.to_json(embedding.data[0].embedding).decode()
    rows = await context.deps.pool.fetch(
        "SELECT source, title, content FROM doc_sections ORDER BY embedding <-> $1 LIMIT 8",
        embedding_json,
    )
    result = "\n\n".join(
        f'# {row["title"]}\nSource: {row["source"]}\n\n{row["content"]}\n' for row in rows
    )
    context.deps.collected.append(f"Search query: {search_query!r}\n\n{result}")
    return result


async def reindex_docs(context: RunContext[Deps]) -> str:
    """Reindex the homelab documentation search database. Incremental -
    only files that changed since the last reindex are re-embedded, so
    calling this when nothing changed is cheap (a few seconds).

    ONLY call this when the user explicitly asks to reindex, rebuild,
    refresh, or update the documentation search index - never as a step
    toward answering an ordinary question, and never speculatively.
    """
    try:
        result = await indexer.reindex(context.deps.pool)
    except Exception as exc:
        result = f"Reindex FAILED: {exc}"
    context.deps.collected.append(result)
    return result


async def answer_question(question: str) -> dict:
    t_start = time.monotonic()
    openai = AsyncOpenAI()
    pool = await asyncpg.create_pool(
        host=PG_HOST, port=PG_PORT, user=PG_USER, password=PG_PASSWORD, database=PG_DATABASE
    )
    try:
        agent, conclude_agent = build_agents()
        deps = Deps(openai=openai, pool=pool)
        try:
            result = await agent.run(
                question, deps=deps, usage_limits=UsageLimits(tool_calls_limit=RETRIEVE_CALL_LIMIT)
            )
            answer = result.output
        except UsageLimitExceeded:
            context = "\n\n---\n\n".join(deps.collected)
            conclude_result = await conclude_agent.run(
                f"QUESTION: {question}\n\nRETRIEVED SO FAR:\n{context}"
            )
            answer = conclude_result.output
        return {
            "question": question,
            "answer": answer,
            "retrieve_calls": deps.retrieve_calls,
            "elapsed_s": round(time.monotonic() - t_start, 1),
        }
    finally:
        await pool.close()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # keep logs quiet; low-traffic internal tool, same as web-search

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._json(200, {"status": "ok"})
            return
        if parsed.path != "/ask":
            self._json(404, {"error": "not found"})
            return

        qs = parse_qs(parsed.query)
        question = qs.get("q", [""])[0]
        if not question:
            self._json(400, {"error": "missing q parameter"})
            return

        try:
            result = asyncio.run(answer_question(question))
            self._json(200, result)
        except Exception as exc:
            self._json(502, {"error": str(exc)})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    server.serve_forever()
