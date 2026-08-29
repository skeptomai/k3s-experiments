#!/usr/bin/env bash
# Run an arbitrary PromQL instant query against nazgul's Prometheus and
# print the results as "label1=val1,label2=val2 -> value" lines.
#
# Exists so gptel's run_shell_k8s tool (or anyone else) can ask Prometheus
# an ad hoc question without reconstructing the curl/--data-urlencode/jq
# pipeline from memory each time -- that reconstruction is the part that's
# actually fragile (URL-encoding, JSON parsing, shell quoting all have to
# survive being embedded in a tool-call's JSON arguments first), not the
# PromQL itself. This script handles the fragile plumbing once; the only
# thing a caller needs to get right is the PromQL expression, a much
# smaller ask. Deliberately generic rather than baking specific metrics in
# here -- cluster-health.sh stays the fixed "everything at once" summary,
# this is for anything else (uptime, one-off metric checks, whatever comes
# up next) without needing a new script per metric.
#
# Usage: prom-query.sh '<promql-expression>'
set -euo pipefail

PROM="http://nazgul.taildd208.ts.net:9090"

if [ $# -ne 1 ]; then
  echo "Usage: $0 '<promql-expression>'" >&2
  exit 1
fi

curl -s -G "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '
  if .status != "success" then
    "Query error: " + (.error // "unknown")
  elif (.data.result | length) == 0 then
    "No data returned for this query."
  else
    .data.result[] |
    (.metric | to_entries | map("\(.key)=\(.value)") | join(",")) +
    " -> " + .value[1]
  end'
