#!/usr/bin/env bash
# open-webui-setup-tools.sh
#
# Idempotently reconstructs the open-webui runtime config that lives ONLY in
# its SQLite DB (manifests/open-webui/*.yaml doesn't cover any of this) --
# the cluster_health Tool, the Jupyter code-interpreter wiring, and the
# Nemotron model's custom_params/system prompt/toolIds. If the open-webui
# PVC is ever lost or you're standing up a fresh instance, this is what
# restores the working state from 2026-08-28 -- see
# docs/open-webui-code-execution.md for the full story of how each piece
# was diagnosed.
#
# Prerequisites (not done by this script):
#   - manifests/open-webui/rbac.yaml and deployment.yaml applied (RBAC +
#     WEBUI_SECRET_KEY + serviceAccountName -- kubectl apply -k manifests/open-webui/)
#   - Jupyter deployed (manifests/jupyter/) with its jupyter-token Secret created
#   - The Nemotron model already added in open-webui (Admin > Models) with
#     id nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4
#
# Usage: ./open-webui-setup-tools.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/../manifests/open-webui/tools"
SERVER="ipc4.taildd208.ts.net"
MODEL_ID="nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4"

echo "=== Reading Jupyter token (stays server-side, never printed here) ==="
# Everything below runs in ONE remote pipeline so the token never lands in
# local shell history or this script's own output -- same reasoning as the
# original setup (see docs/open-webui-code-execution.md).

echo "=== Setting code_interpreter/code_execution config (Jupyter engine) ==="
ssh "cb@$SERVER" '
TOKEN=$(sudo kubectl get secret jupyter-token -n jupyter -o jsonpath="{.data.token}" | base64 -d)
sudo kubectl exec -n open-webui deploy/open-webui -i -- python3 -c "
import sqlite3, json, sys
token = sys.argv[1]
conn = sqlite3.connect(\"/app/backend/data/webui.db\")
c = conn.cursor()
updates = {
    \"code_interpreter.engine\": \"jupyter\",
    \"code_interpreter.jupyter.url\": \"http://jupyter.jupyter.svc.cluster.local\",
    \"code_interpreter.jupyter.auth\": \"token\",
    \"code_interpreter.jupyter.auth_token\": token,
    \"code_execution.engine\": \"jupyter\",
    \"code_execution.jupyter.url\": \"http://jupyter.jupyter.svc.cluster.local\",
    \"code_execution.jupyter.auth\": \"token\",
    \"code_execution.jupyter.auth_token\": token,
}
for k, v in updates.items():
    c.execute(\"UPDATE config SET value = ? WHERE key = ?\", (json.dumps(v), k))
conn.commit()
print(\"jupyter config: OK\")
" "$TOKEN"
' 2>&1

echo "=== Setting code_interpreter.prompt_template ==="
cat "$TOOLS_DIR/code_interpreter_prompt_template.txt" | ssh "cb@$SERVER" '
sudo kubectl exec -n open-webui deploy/open-webui -i -- python3 -c "
import sqlite3, json, sys
prompt = sys.stdin.read()
conn = sqlite3.connect(\"/app/backend/data/webui.db\")
c = conn.cursor()
c.execute(\"UPDATE config SET value = ? WHERE key = ?\", (json.dumps(prompt), \"code_interpreter.prompt_template\"))
conn.commit()
print(\"prompt_template: OK, length\", len(prompt))
"
' 2>&1

echo "=== Registering cluster_health Tool ==="
cat "$TOOLS_DIR/cluster_health.py" | ssh "cb@$SERVER" '
sudo kubectl exec -n open-webui deploy/open-webui -i -- python3 -c "
import sqlite3, json, sys, time
content = sys.stdin.read()
conn = sqlite3.connect(\"/app/backend/data/webui.db\")
c = conn.cursor()
now = int(time.time())
c.execute(\"SELECT id FROM user WHERE role = \x27admin\x27 LIMIT 1\")
admin_id = c.fetchone()[0]
meta = json.dumps({
    \"description\": \"Check k3s cluster node/pod health and CPU temperatures.\",
    \"manifest\": {\"title\": \"Cluster Health\", \"description\": \"Check k3s cluster node/pod health and CPU temperatures.\"},
    \"has_user_valves\": False,
})
# The specs field is NOT auto-derived when inserting via raw SQL (only the
# admin UI/API parses the function signature+docstring into this) -- get
# this wrong (e.g. leave it []) and the model has no real schema to work
# from: it hallucinates arguments the function does not take, and
# open-webui cannot dispatch the call at all (\"Tool not found\"). This
# exact bug is what this script exists to prevent recurring.
specs = [{
    \"name\": \"cluster_health\",
    \"description\": \"Check the k3s clusters node/pod health and CPU temperatures. Use this whenever asked to check cluster health, cluster status, or node temperatures -- do not guess, call this instead.\",
    \"parameters\": {\"properties\": {}, \"required\": [], \"type\": \"object\"},
}]
c.execute(\"SELECT id FROM tool WHERE id = ?\", (\"cluster_health\",))
if c.fetchone():
    c.execute(\"UPDATE tool SET content = ?, specs = ?, meta = ?, updated_at = ? WHERE id = ?\",
        (content, json.dumps(specs), meta, now, \"cluster_health\"))
    print(\"cluster_health tool: updated\")
else:
    c.execute(\"INSERT INTO tool (id, user_id, name, content, specs, meta, valves, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)\",
        (\"cluster_health\", admin_id, \"Cluster Health\", content, json.dumps(specs), meta, \"{}\", now, now))
    print(\"cluster_health tool: created\")
conn.commit()
"
' 2>&1

echo "=== Setting Nemotron model params (enable_thinking, system prompt, toolIds) ==="
cat "$TOOLS_DIR/nemotron_system_prompt.txt" | ssh "cb@$SERVER" "
sudo kubectl exec -n open-webui deploy/open-webui -i -- python3 -c \"
import sqlite3, json, sys
system_prompt = sys.stdin.read()
conn = sqlite3.connect('/app/backend/data/webui.db')
c = conn.cursor()
c.execute('SELECT params, meta FROM model WHERE id=?', ('$MODEL_ID',))
row = c.fetchone()
if not row:
    print('ERROR: model $MODEL_ID not found -- add it in Admin > Models first')
    sys.exit(1)
params_raw, meta_raw = row
params = json.loads(params_raw) if params_raw else {}
meta = json.loads(meta_raw) if meta_raw else {}
params['function_calling'] = 'native'
params['custom_params'] = {'chat_template_kwargs': {'enable_thinking': False}}
params['system'] = system_prompt
tool_ids = set(meta.get('toolIds') or [])
tool_ids.add('web_search')
tool_ids.add('cluster_health')
meta['toolIds'] = sorted(tool_ids)
c.execute('UPDATE model SET params = ?, meta = ? WHERE id = ?', (json.dumps(params), json.dumps(meta), '$MODEL_ID'))
conn.commit()
print('model params/meta: OK, toolIds =', meta['toolIds'])
\"
" 2>&1

echo "=== Restarting open-webui (config table settings are cached at startup) ==="
ssh "cb@$SERVER" 'sudo kubectl rollout restart deployment open-webui -n open-webui && sudo kubectl rollout status deployment open-webui -n open-webui --timeout=120s' 2>&1

echo
echo "=== Done. Verify: ==="
echo "  - Log into open-webui, open a NEW chat with Nemotron"
echo "  - Toggle 'Code Interpreter' on for that chat (per-chat, not persisted -- see docs)"
echo "  - Ask: 'check cluster health and temps' -- should call cluster_health directly"
echo "  - Ask a computation question -- should use the Jupyter code interpreter, not web search"
