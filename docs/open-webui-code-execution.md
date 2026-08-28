# open-webui: real code execution + cluster tools for Nemotron

How Nemotron (via open-webui) got real backend code execution and a
working `cluster_health` tool, replacing the browser-sandboxed Pyodide
interpreter with nothing wired to the cluster at all. Debugged over
2026-08-26 to 2026-08-28; this is the reconstructable end state plus the
real bugs hit along the way, since several of them will recur if this ever
needs to be rebuilt from scratch (fresh install, PVC loss, etc.).

**To reconstruct this state on a fresh/reset open-webui instance, run
`scripts/open-webui-setup-tools.sh`** (idempotent, safe to re-run). This
doc explains *why* each piece exists; the script and the files in
`manifests/open-webui/tools/` are the actual source of truth.

## The three separate mechanisms, not to be confused

open-webui has three distinct extensibility surfaces that all sound
similar but work completely differently:

1. **Tools** (`Workspace -> Tools`) -- Python functions the model calls via
   native function-calling. `web_search` and `cluster_health` are both
   this. Live in the `tool` DB table. Must be explicitly attached to a
   model's `toolIds` (in `model.meta`) to be offered at all -- being
   "enabled" globally is not sufficient.
2. **Code Interpreter** (`Admin Settings -> Code Execution`) -- lets the
   model write and run arbitrary Python. Two engines: `pyodide` (default,
   runs in the *browser* as sandboxed WebAssembly -- zero network access,
   zero cluster access, by design) or `jupyter` (a real backend). This is
   NOT a Tool and doesn't show up in the Tools list; it's a separate
   per-chat toggle plus a system-prompt injection that tells the model how
   to format runnable code blocks.
3. **Functions** (`Workspace -> Functions`) -- pipe/filter/action plugins.
   Unused here; the `function` table is empty.

Confusing (1) and (2) cost real debugging time -- e.g. assuming a "code
execution" capability the user remembered was a Tool, when it was
actually the built-in Pyodide interpreter (see "arbitrary code executor"
in the session transcript).

## Fix 1: Pyodide -> Jupyter

Pyodide has no network path to anything -- confirmed by finding an
already-deployed, unrelated Jupyter server already running in the cluster
(`manifests/jupyter/`, `jupyter.jupyter.svc.cluster.local`, token-auth via
the `jupyter-token` Secret) and pointing `code_interpreter`/
`code_execution` engine + `jupyter.url` + `jupyter.auth_token` at it
instead. In-cluster URL, not the tailnet hostname, since both open-webui
and Jupyter are cluster-internal.

**Gotcha:** this lives in the `config` DB table, which open-webui reads
**once at startup**, unlike `model.params`/`model.meta` (read fresh per
request). Changing `config` values requires a pod restart to take effect;
changing model-level fields does not.

## Fix 2: Nemotron's reasoning wasn't suppressed for this connection

`gptel` (the Emacs client, different codebase entirely) already sends
`chat_template_kwargs: {enable_thinking: false}` to Spark's vLLM endpoint
-- Nemotron-3-Super is a hybrid reasoning model and without this, every
response includes a full visible chain-of-thought first, which for a
120B model on a single Blackwell GPU can take minutes even for trivial
prompts. open-webui's connection to the *same backend* is entirely
separate and had no equivalent override.

open-webui doesn't have a generic "extra request params per connection"
field (`openai.api_configs` only covers `model_ids`/`prefix_id`/tags,
not arbitrary body params). The actual mechanism: `model.params.custom_params`,
which `apply_model_params_to_body_openai()`
(`utils/payload.py`) deep-merges into the outgoing request body. This is
the open-webui equivalent of gptel's `:request-params`.

## Fix 3: `cluster_health` Tool + RBAC

New Tool (`manifests/open-webui/tools/cluster_health.py`), same pattern as
the existing `web_search` Tool: pure-stdlib Python (`urllib`, no new pip
dependency), runs server-side inside the open-webui pod.

- **k8s API**: in-cluster, via the pod's own ServiceAccount token
  (`/var/run/secrets/kubernetes.io/serviceaccount/token`) against
  `https://kubernetes.default.svc`. Needed a dedicated ServiceAccount +
  ClusterRole (`manifests/open-webui/rbac.yaml`) -- the pod was previously
  running as `default` with a token mounted but zero RBAC bound, so any
  k8s API call would 403. Scoped to exactly `get`/`list`/`watch` on
  `nodes`/`pods`, cluster-wide (both are non-namespaced concepts) -- no
  write verbs, no other resources.
- **Temps**: Prometheus on nazgul (`192.168.89.2:9090`, LAN-reachable
  directly from cluster pods, same as the Zot registry pattern elsewhere
  in this repo) -- `node_hwmon_temp_celsius{chip="platform_coretemp_0",sensor="temp1"}`
  for per-node CPU package temp, `spark_gpu_temperature_celsius` for
  Spark. **Not authenticated** -- a real, accepted gap (nothing else
  calling Prometheus in this cluster is authenticated either; SPIRE
  workload identity was considered and rejected as overkill for this,
  see session notes -- SPIRE solves workload-to-workload mTLS, not
  pod-to-k8s-API auth, which RBAC already handles correctly).

### The real bug: `tool.specs` isn't auto-derived from raw SQL inserts

This was the actual root cause of the tool "not working" across several
different-looking symptoms (model inventing a nonexistent `action`
parameter, open-webui reporting `Tool "cluster_health" not found` on
dispatch). The `tool` table's `specs` column is normally populated by
open-webui's own admin API, which parses the Python function's signature
+ docstring into a proper JSON schema. Registering the tool via a raw SQL
`INSERT` (necessary here since there's no browser session with API auth
in this context) skipped that step entirely -- `specs` was left as `[]`.

Result: the model had no real schema to call the tool with (it guessed at
a plausible-sounding `{"action": "get_nodes"}` based on generic training
data about "cluster health" tools), and open-webui's dispatcher had
nothing to route the call to.

**Fix:** hand-write the correct `specs` JSON (verified against the
already-working `web_search` tool's `specs` as the reference format) --
`[{"name": ..., "description": ..., "parameters": {"type": "object", "properties": {}, "required": []}}]`.
`scripts/open-webui-setup-tools.sh` does this correctly; don't insert a
Tool via raw SQL without it again.

Confirmed via direct, isolated `curl` tests against vLLM's
`/v1/chat/completions` (and separately `/v1/responses` -- open-webui's
`function_calling: native` models route through the newer Responses API,
a different endpoint/response shape than `/v1/chat/completions`, worth
knowing if debugging this again) with a hand-built matching schema:
Nemotron correctly emitted a `tool_calls`/`function_call` response
immediately, with zero arguments, exactly as it should. The model and
vLLM's native function-calling were never the problem -- the registration
was.

## Fix 4: tool selection (code interpreter vs. web search vs. cluster_health)

Even with everything above wired correctly, Nemotron would sometimes
reach for the wrong capability -- e.g. querying web search with a bare
arithmetic expression, or writing Python that assumes `kubectl` exists
inside the Jupyter kernel (it doesn't and never will -- Jupyter is
deliberately isolated from the cluster API by design, see
`manifests/jupyter/deployment.yaml`'s `automountServiceAccountToken: false`
comment).

Two system-prompt-level fixes, both needed:

1. **`code_interpreter.prompt_template`**
   (`manifests/open-webui/tools/code_interpreter_prompt_template.txt`) --
   rewrites open-webui's built-in default (which incorrectly claims "the
   Python shell runs directly in the user's browser," stale Pyodide-era
   wording) and adds explicit tool-selection guidance: use the
   interpreter for any well-defined computation, never web search: and an
   anti-looping instruction (stop and ask after 2 failed attempts instead
   of retrying forever -- this was observed as a real runaway tool-call
   loop, not a hypothetical).
2. **Nemotron's own system prompt**
   (`manifests/open-webui/tools/nemotron_system_prompt.txt`,
   `model.params.system`) -- the actual equivalent of this repo's own
   `CLAUDE.md` for Claude Code: explains this is a private, non-public
   cluster (so web search can never help with infra-specific failures),
   and draws the explicit boundary between `cluster_health` (real cluster
   access) and the Jupyter code interpreter (zero cluster access, generic
   computation only).

**Why both are needed, not just one:** the code-interpreter prompt
governs behavior *inside* a code-interpreter turn; the model-level system
prompt governs which capability gets reached for *before* that. Confirmed
both empirically via isolated vLLM API tests before rolling out -- a
request with the tool schema + system prompt together correctly picked
`cluster_health` over web_search or code execution every time in
isolation. (When it still failed via the real open-webui UI after that
confirmation, the actual cause was the `specs` bug above, not the
prompts -- worth remembering that a request looking "correct" in
isolation doesn't guarantee the live app is constructing the same
request; verify via the DB's persisted `history.messages[].output` field,
not just user-visible symptoms, when this class of bug recurs.)

## Fix 7: broadened read-only cluster access (`k8s_explore`)

`cluster_health` answers one fixed question. For genuine open-ended
exploration ("why is this pod pending", "what deployments exist in
namespace X"), added a second Tool, `k8s_explore`
(`manifests/open-webui/tools/k8s_explore.py`), with three functions:

- `k8s_get(resource, namespace, name, label_selector)` -- list or get any
  resource in an explicit allowlist (`RESOURCE_MAP` in the file: nodes,
  pods, services, endpoints, configmaps, events, namespaces, PVCs, RCs,
  deployments, replicasets, daemonsets, statefulsets, jobs, cronjobs).
- `k8s_describe(resource, name, namespace)` -- one object's status plus
  its recent related Events, which are usually the actual answer to "why
  is X pending/failing" and are deliberately surfaced *before* the raw
  spec dump so they survive the `MAX_OUTPUT_CHARS` truncation (a pod with
  many `volumeMounts` was observed pushing events past the truncation
  point before this ordering fix).
- `k8s_logs(pod_name, namespace, container, tail_lines)` -- recent log
  tail only; not exec, no interactivity.

**Design decision (2026-08-28):** considered MCP (open-webui has native
support since v0.6.31) and a Jupyter-side `kubectl` install, rejected
both -- MCP K8s server projects in this space are mostly immature
single-maintainer efforts, and giving Jupyter cluster credentials would
undo its deliberate isolation (`automountServiceAccountToken: false`,
see Fix 4). Extending the already-proven Tool pattern was simpler and
kept the trust boundary in one place. Mutating actions (restarts,
deletes, applies) deliberately stay out of open-webui entirely and
remain in gptel/Claude Code, which has a stronger trust boundary (a
human physically present, SSH under the user's own key) than a chat
session reachable via Funnel.

**RBAC broadened accordingly** (`manifests/open-webui/rbac.yaml`, still
`get`/`list`/`watch` only) to cover the resources above. Two things are
permanently excluded and called out in the manifest's own comments:
`secrets` (any verb -- read-only RBAC on other resources still doesn't
protect secret *values*) and `pods/exec`/`pods/attach`/`pods/portforward`
(interactive execution is a different risk class than reading state).
`k8s_explore.py` also enforces its own `RESOURCE_MAP` allowlist in code,
independent of RBAC, as defense-in-depth -- if RBAC is ever accidentally
broadened later, the tool still refuses anything not on its own list.

**Gotcha hit while deploying this:** `manifests/open-webui/` is
Flux-managed straight from GitHub (see repo `CLAUDE.md`). A `kubectl
apply -f manifests/open-webui/rbac.yaml` run manually against the live
cluster *appeared* to succeed, but Flux's next reconcile silently
reverted it back to whatever was last committed, since the broadened
version hadn't been pushed yet -- caught by `kubectl auth can-i list
deployments --as=system:serviceaccount:open-webui:open-webui` returning
`no` even after the manual apply. **Lesson: for anything under Flux's
management paths, the fix isn't real until it's committed and pushed,
full stop** -- a live `kubectl apply` there is at best a temporary,
Flux-will-undo-it test, never the actual deployment step.

`scripts/open-webui-setup-tools.sh` was also refactored this round: the
three separate SSH round-trips (Jupyter config, tool registration, model
params) became one JSON payload built locally and piped through a single
remote `python3 -c` invocation, ending in one pod restart. Hit and fixed
a real bash-quoting bug along the way: a literal apostrophe *anywhere*
inside the outer bash single-quoted `ssh ... '...'` block -- including
inside an English comment ("open-webui's own...") or Python f-string
dict-key syntax (`tool['id']`) -- prematurely terminates the outer bash
string regardless of the inner language's own quoting rules. Fixed by
rewording comments to avoid contractions and replacing f-string dict-key
access with pre-extracted plain variables before printing.

## Known remaining gap: no default-on toggle for Code Interpreter

Unlike Tools (`model.meta.toolIds`, a real default-attachment mechanism),
no equivalent "default on for every new chat" setting was found for the
Code Interpreter feature in this open-webui version -- it appears to be
frontend-only per-chat state. Confirmed by grepping the backend for a
model-level features-default mechanism and finding nothing; not
confirmed by reading the frontend bundle, so this could still exist and
just wasn't found. Until/unless resolved, Code Interpreter needs manual
per-chat toggling (the Tools-list checkbox for `cluster_health` does NOT
need this -- toolIds attachment is sufficient for Tools specifically).

## Fix 5: session-expiry bug (WEBUI_SECRET_KEY)

Unrelated to code execution, but hit hard during this same debugging
session because open-webui restarted repeatedly (config changes above,
each requiring a restart) -- `WEBUI_SECRET_KEY` was unset, so
`start.sh` auto-generates a random one and writes it to
`/app/backend/.webui_secret_key`. That path is **outside** the PVC mount
(`/app/backend/data`), so it lives on the ephemeral container filesystem
-- every new pod (any rollout, any deployment change) got a fresh random
key, instantly invalidating every existing session regardless of the
nominal 4-week JWT expiry (`auth.jwt_expiry` config key). This is why
sessions felt like they lasted minutes, not weeks.

**Fix:** `open-webui-secret-key` Secret, created once out-of-band (same
pattern as `open-webui-admin`/`open-webui-oidc`/`jupyter-token` -- not in
git):

```bash
kubectl create secret generic open-webui-secret-key -n open-webui \
  --from-literal=key=$(openssl rand -base64 24)
```

Wired into `manifests/open-webui/deployment.yaml` via `WEBUI_SECRET_KEY`
env var / `secretKeyRef`. Now stable across restarts.

## Fix 6: Authentik access token lifetime

Separately, Authentik's OAuth2 provider for the "Open WebUI" application
had `access_token_validity: hours=1` (default) -- short enough that a
single long debugging session would cross it, and (unconfirmed, but
suspected) open-webui's OIDC integration may not reliably silently-refresh
using the 30-day refresh token, causing a forced re-login mid-session.
Bumped to `hours=24` via Django shell inside the `authentik-server` pod
(no UI/API shortcut found for this specific field):

```python
from authentik.providers.oauth2.models import OAuth2Provider
p = OAuth2Provider.objects.get(name="Open WebUI")
p.access_token_validity = "hours=24"
p.save()
```

Not scripted (one-time, low-frequency change, and Authentik's Django
shell requires exec-ing into a specific pod name that changes per
deployment) -- if this needs to be reapplied, redo it manually with the
above.
