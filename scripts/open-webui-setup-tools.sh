#!/usr/bin/env bash
# open-webui-setup-tools.sh
#
# Idempotently reconstructs the open-webui runtime config that lives ONLY in
# its SQLite DB (manifests/open-webui/*.yaml doesn't cover any of this) --
# the cluster_health/k8s_explore Tools, the Jupyter code-interpreter wiring,
# and the Nemotron model's custom_params/system prompt/toolIds. If the
# open-webui PVC is ever lost or you're standing up a fresh instance, this is
# what restores the working state -- see docs/open-webui-code-execution.md
# for the full story of how each piece was diagnosed.
#
# Builds one JSON payload locally (Python) and ships it as a single argument
# to one remote python3 invocation that does all the DB work -- avoids
# stacking fragile nested bash/SSH quoting across multiple round-trips,
# which is how earlier versions of this script grew increasingly awkward as
# more tools were added.
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
PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$PAYLOAD_FILE"' EXIT

echo "=== Building payload locally ==="
python3 - "$TOOLS_DIR" "$MODEL_ID" > "$PAYLOAD_FILE" <<'PYEOF'
import json, sys

tools_dir, model_id = sys.argv[1], sys.argv[2]

def read(name):
    with open(f"{tools_dir}/{name}") as f:
        return f.read()

tools = [
    {
        "id": "cluster_health",
        "name": "Cluster Health",
        "content": read("cluster_health.py"),
        "description": "Check k3s cluster node/pod health and CPU temperatures.",
        "specs": [{
            "name": "cluster_health",
            "description": "Check the k3s clusters node/pod health and CPU temperatures. Use this whenever asked to check cluster health, cluster status, or node temperatures -- do not guess, call this instead.",
            "parameters": {"properties": {}, "required": [], "type": "object"},
        }],
    },
    {
        "id": "k8s_explore",
        "name": "K8s Explore",
        "content": read("k8s_explore.py"),
        "description": "Read-only exploration of the k3s cluster -- list/get resources, describe an object with its recent events, or read pod logs.",
        "specs": [
            {
                "name": "k8s_get",
                "description": "List or get Kubernetes resources (read-only). Supports: nodes, pods, services, endpoints, configmaps, events, namespaces, persistentvolumeclaims, replicationcontrollers, deployments, replicasets, daemonsets, statefulsets, jobs, cronjobs. Never supports secrets.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "resource": {"type": "string", "description": "Resource type, e.g. \"pods\", \"deployments\", \"events\". Plural, lowercase."},
                        "namespace": {"type": "string", "description": "Namespace to scope to. Empty to list across all namespaces or for cluster-scoped resources."},
                        "name": {"type": "string", "description": "Specific object name. Empty to list all matching objects."},
                        "label_selector": {"type": "string", "description": "Optional label selector to filter a list, e.g. \"app=open-webui\"."},
                    },
                    "required": ["resource"],
                },
            },
            {
                "name": "k8s_describe",
                "description": "Get full detail for one Kubernetes object plus its recent related Events -- usually the actual answer to \"why is this pending/failing\". Never supports secrets.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "resource": {"type": "string", "description": "Resource type, e.g. \"pods\", \"deployments\"."},
                        "name": {"type": "string", "description": "The specific object's name."},
                        "namespace": {"type": "string", "description": "Namespace (required for namespaced resources)."},
                    },
                    "required": ["resource", "name"],
                },
            },
            {
                "name": "k8s_logs",
                "description": "Read the recent log tail for a pod (read-only; not exec, not an interactive shell).",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "pod_name": {"type": "string", "description": "The pod's name."},
                        "namespace": {"type": "string", "description": "The pod's namespace."},
                        "container": {"type": "string", "description": "Container name, if the pod has more than one."},
                        "tail_lines": {"type": "integer", "description": "How many recent lines to fetch (default 100, capped at 500)."},
                    },
                    "required": ["pod_name", "namespace"],
                },
            },
        ],
    },
]

payload = {
    "jupyter_url": "http://jupyter.jupyter.svc.cluster.local",
    "code_interpreter_prompt_template": read("code_interpreter_prompt_template.txt"),
    "nemotron_system_prompt": read("nemotron_system_prompt.txt"),
    "model_id": model_id,
    "tools": tools,
}
json.dump(payload, sys.stdout)
PYEOF

echo "=== Shipping payload + Jupyter token to open-webui, applying (token never printed locally) ==="
cat "$PAYLOAD_FILE" | ssh "cb@$SERVER" '
JUPYTER_TOKEN=$(sudo kubectl get secret jupyter-token -n jupyter -o jsonpath="{.data.token}" | base64 -d)
sudo kubectl exec -n open-webui deploy/open-webui -i -- python3 -c "
import sqlite3, json, sys, time

payload = json.load(sys.stdin)
jupyter_token = sys.argv[1]
conn = sqlite3.connect(\"/app/backend/data/webui.db\")
c = conn.cursor()

# --- Jupyter code-interpreter wiring (config table -- cached at open-webui
# startup, needs the restart at the end of this script to take effect) ---
config_updates = {
    \"code_interpreter.engine\": \"jupyter\",
    \"code_interpreter.jupyter.url\": payload[\"jupyter_url\"],
    \"code_interpreter.jupyter.auth\": \"token\",
    \"code_interpreter.jupyter.auth_token\": jupyter_token,
    \"code_interpreter.prompt_template\": payload[\"code_interpreter_prompt_template\"],
    \"code_execution.engine\": \"jupyter\",
    \"code_execution.jupyter.url\": payload[\"jupyter_url\"],
    \"code_execution.jupyter.auth\": \"token\",
    \"code_execution.jupyter.auth_token\": jupyter_token,
}
for k, v in config_updates.items():
    c.execute(\"UPDATE config SET value = ? WHERE key = ?\", (json.dumps(v), k))
print(\"jupyter/code-interpreter config: OK\")

# --- Tool registration (tool table -- specs must be hand-correct here,
# raw SQL inserts skip the auto signature/docstring-to-schema derivation
# that only happens via the admin API; see docs/open-webui-code-execution.md) ---
c.execute(\"SELECT id FROM user WHERE role = \x27admin\x27 LIMIT 1\")
admin_id = c.fetchone()[0]
now = int(time.time())
tool_ids = []
for tool in payload[\"tools\"]:
    tid = tool[\"id\"]
    tool_ids.append(tid)
    meta = json.dumps({
        \"description\": tool[\"description\"],
        \"manifest\": {\"title\": tool[\"name\"], \"description\": tool[\"description\"]},
        \"has_user_valves\": False,
    })
    specs = json.dumps(tool[\"specs\"])
    c.execute(\"SELECT id FROM tool WHERE id = ?\", (tid,))
    if c.fetchone():
        c.execute(\"UPDATE tool SET content = ?, specs = ?, meta = ?, updated_at = ? WHERE id = ?\",
            (tool[\"content\"], specs, meta, now, tid))
        print(\"tool\", tid, \": updated\")
    else:
        c.execute(\"INSERT INTO tool (id, user_id, name, content, specs, meta, valves, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)\",
            (tid, admin_id, tool[\"name\"], tool[\"content\"], specs, meta, \"{}\", now, now))
        print(\"tool\", tid, \": created\")

# --- Nemotron model params/meta (model table -- read live, no restart needed) ---
target_model_id = payload[\"model_id\"]
c.execute(\"SELECT params, meta FROM model WHERE id=?\", (target_model_id,))
row = c.fetchone()
if not row:
    print(\"ERROR: model\", target_model_id, \"not found -- add it in Admin > Models first\")
    sys.exit(1)
params_raw, meta_raw = row
params = json.loads(params_raw) if params_raw else {}
meta = json.loads(meta_raw) if meta_raw else {}
params[\"function_calling\"] = \"native\"
params[\"custom_params\"] = {\"chat_template_kwargs\": {\"enable_thinking\": False}}
params[\"system\"] = payload[\"nemotron_system_prompt\"]
existing_tool_ids = set(meta.get(\"toolIds\") or [])
existing_tool_ids.add(\"web_search\")
existing_tool_ids.update(tool_ids)
meta[\"toolIds\"] = sorted(existing_tool_ids)
c.execute(\"UPDATE model SET params = ?, meta = ? WHERE id = ?\", (json.dumps(params), json.dumps(meta), payload[\"model_id\"]))
print(\"model params/meta: OK, toolIds =\", meta[\"toolIds\"])

conn.commit()
" "$JUPYTER_TOKEN"
' 2>&1

echo "=== Restarting open-webui (config table settings are cached at startup) ==="
ssh "cb@$SERVER" 'sudo kubectl rollout restart deployment open-webui -n open-webui && sudo kubectl rollout status deployment open-webui -n open-webui --timeout=120s' 2>&1

echo
echo "=== Done. Verify: ==="
echo "  - Log into open-webui, open a NEW chat with Nemotron"
echo "  - Toggle 'Code Interpreter' on for that chat (per-chat, not persisted -- see docs)"
echo "  - Ask: 'check cluster health and temps' -- should call cluster_health directly"
echo "  - Ask: 'list pods in the spire namespace and describe the pending one' -- should use k8s_get/k8s_describe"
echo "  - Ask a computation question -- should use the Jupyter code interpreter, not web search"
