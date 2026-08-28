#!/usr/bin/env python3
"""Minimal web search proxy -- wraps ddgs (DuckDuckGo), no API key needed.

Built for gptel's web_search tool (omen must stay stateless -- no local
Python deps there, see k3s-experiments README for this service). Mirrors
the same library Open WebUI's own web_search tool already uses
(manifests/open-webui, k3s-experiments#16), just as a standalone HTTP
service instead of an Open WebUI-internal tool.
"""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

from ddgs import DDGS


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # keep logs quiet; this is a low-traffic internal tool

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._json(200, {"status": "ok"})
            return
        if parsed.path != "/search":
            self._json(404, {"error": "not found"})
            return

        qs = parse_qs(parsed.query)
        query = qs.get("q", [""])[0]
        if not query:
            self._json(400, {"error": "missing q parameter"})
            return
        max_results = min(int(qs.get("max_results", ["5"])[0]), 10)

        # ddgs rotates across backends internally and sometimes *raises*
        # (rather than returning []) when the backend it happened to pick
        # is transiently flaky/rate-limited -- observed directly: the same
        # query that raised "No results found." here succeeded immediately
        # after with a fresh DDGS() instance run by hand. One retry with a
        # fresh instance (it re-picks a backend/user-agent) absorbs that
        # instead of surfacing a transient hiccup as a hard failure.
        last_exc = None
        for attempt in range(2):
            try:
                results = DDGS().text(query, max_results=max_results)
                self._json(200, {
                    "query": query,
                    "results": [
                        {"title": r.get("title"), "url": r.get("href"), "snippet": r.get("body")}
                        for r in results
                    ],
                })
                return
            except Exception as exc:
                last_exc = exc
                if attempt == 0:
                    time.sleep(1)
        # Distinct from a genuine zero-result search (200, empty results
        # list) so callers -- gptel's web_search tool included -- can tell
        # "the web really has nothing" apart from "the backend failed twice
        # in a row" instead of collapsing both into one generic message.
        self._json(502, {"error": str(last_exc)})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    server.serve_forever()
