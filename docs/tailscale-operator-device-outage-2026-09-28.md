# Tailscale Operator Device Outage — 2026-09-28/29 Postmortem

## Summary

Six tailnet-exposed apps (`homelab-rag`, `gruesome`, `open-webui`, `web-search`,
`jupyter`, `authentik` — all plain `tailscale.com/expose` Service-mode proxies)
went unreachable for over a day. The investigation took a long, costly detour
through a Tailscale Services (ProxyGroup/VIP) migration that wasn't the right
fix and was later reverted, and one step of that detour briefly broke **core**
tailnet connectivity (ipc4, nazgul unreachable) cluster-wide. The actual root
cause of the original outage, and the actual fix, were both much simpler than
the path taken to find them. This doc exists so that path isn't repeated.

**If you're here because tailnet hostnames for k8s-operator-exposed apps have
gone dark again, skip to "Proven-safe recovery procedure" below.**

## Timeline

- **2026-09-27 ~05:02 PDT**: tailscale-operator crashed at the cluster's
  scheduled 05:00 daily power-on — CoreDNS wasn't ready yet when the operator
  tried to reach the Kubernetes API (`dial tcp: lookup kubernetes.default.svc
  ...: connection refused`). It restarted and became healthy within about a
  minute, same as any normal CrashLoopBackOff recovery.
- Sometime after that restart, all six Service-mode proxies lost `tailscale
  serve` config and became unreachable. This is the part that did **not**
  self-correct — see "Root cause" below.
- **2026-09-28, most of the day**: diagnosed (wrongly, at first) as needing a
  migration to Tailscale's newer ProxyGroup/Services architecture. That
  migration was built, and getting it working required an OAuth scope change
  and an ACL grants change — the grants change broke core tailnet
  connectivity for about 10 minutes until reverted.
- **2026-09-28 evening**: migration reverted back to plain Service-mode
  (proven still functional via `postgres-pgvector`, which had been on that
  exact pattern the whole time and never stopped working). Real root cause of
  the *original* outage was never conclusively identified — see below — but
  the actual blocker turned out to be leftover Tailscale Service (`svc:`)
  objects and orphaned per-proxy Secrets, both self-inflicted during the
  detour, not anything wrong with plain Service-mode itself.
- **2026-09-29 ~01:30 PDT**: all six apps restored on their correct plain
  tailnet hostnames.

## Root cause(s) — be precise about what's actually confirmed

**Confirmed, direct evidence:** the operator crashes at the cluster's
scheduled ~05:00 daily power-on because CoreDNS isn't ready yet. This has now
been observed on 2026-09-27 and again on 2026-09-28, identical error both
times. **Not yet fixed** — see "Still open" below.

**Not confirmed:** *why* the six proxies' `tailscale serve` config specifically
stayed broken after that first crash, for over a day, instead of
self-correcting on the next successful reconcile. The investigation initially
concluded this was because a newer operator reconciler (`service-pg-reconciler`)
had started skipping plain-annotation Services and could no longer generate
serve config for them at all. **That conclusion was likely wrong** — proven
by the fact `postgres-pgvector`, on the identical plain-annotation pattern,
was never affected and kept working the entire time. The real explanation for
the original stuck state was never nailed down before the investigation moved
on to (unnecessarily) migrating architectures. If this happens again, don't
assume ProxyGroup is required — see the false-signal warning below first.

## A diagnostic that lies: `tailscale serve status`

`tailscale serve status` reporting "No serve config" was used, at first, as
the signal that a proxy was broken. **This is not a meaningful health check
for plain Service-mode proxies.** A proxy confirmed live and working
(`postgres-pgvector`, mid-connection, reachable) shows the identical "No
serve config" output. `serve` is an HTTP/HTTPS reverse-proxy feature, mostly
relevant to Ingress/Funnel mode — plain L3 Service-mode forwarding doesn't
use it at all, working or not.

**Use an actual connection test instead**: `curl` or `nc` against the
tailnet hostname/port. That's the only reliable signal.

## The ProxyGroup/Tailscale-Services detour — don't repeat this

A migration to `ProxyGroup` + `loadBalancerClass: tailscale` (Tailscale's
newer "Services"/VIP architecture) was attempted, based on operator log lines
like `"[unexpected] no ProxyGroup annotation, skipping Tailscale Service
provisioning"`. In hindsight this was the wrong move for this cluster:

- It requires an OAuth client scope (**"Services" — write**, distinct from
  "Devices Core") that the operator's OAuth client didn't have. Getting a 404
  creating Tailscale Services was the first symptom.
- It requires a **separate ACL grants entry** referencing `svc:<name>`
  destinations — the tailnet's existing fully-permissive wildcard grant
  (`{"src":["*"],"dst":["*"],"ip":["*"]}`) does **not** cover the `svc:`
  namespace. Adding a second grants entry
  (`{"src":["*"],"dst":["svc:...", ...],"ip":["*"]}`) alongside the wildcard
  **broke core tailnet connectivity cluster-wide** (ipc4, nazgul unreachable)
  for about 10 minutes until reverted. The exact mechanism of *why* two
  grants entries together broke general routing was never root-caused — avoid
  touching tailnet ACL grants again without a much stronger reason and a
  tested rollback plan.
- Plain Service-mode (`tailscale.com/expose` + `tailscale.com/hostname`,
  `type: ClusterIP`, no ProxyGroup) is the current, correct pattern for this
  cluster. It's simpler, requires none of the above, and — per
  `postgres-pgvector` — was never actually broken by any of this. **Don't
  re-attempt the ProxyGroup migration without a concrete reason and a tested
  rollback plan.**

The manifests were reverted; see git history on `manifests/*/service.yaml`,
`manifests/authentik/helmrelease.yaml`, and the removed
`manifests/tailscale-operator/proxygroup.yaml` /
`manifests/authentik/service-tailnet.yaml` for the exact diff.

## The actual self-inflicted damage, and the rule that avoids it

While cleaning up during the ProxyGroup detour, stale Tailscale **devices**
for the six apps were deleted directly via the Tailscale API
(`DELETE /api/v2/device/{id}`) to free up their names — **without** also
deleting their corresponding Kubernetes `StatefulSet` + `Secret`. This left
each proxy's Secret pointing at a device identity that no longer existed. The
result: the pod's `tailscaled` correctly detected its key was invalid,
correctly requested a new one from the operator (`Waiting for operator to
provide new auth key (max wait: 10m0s)` — this timeout is hardcoded in
Tailscale's own `containerboot` binary, not configurable here) — and the
operator never provided one. No error, no retry visible in operator logs —
it simply never reconciled those StatefulSets again. They sat stuck in
`NeedsLogin` indefinitely.

**The rule: never delete a Tailscale device via the API without also
deleting its StatefulSet + Secret in the same action, and vice versa.**
Partial cleanup (one but not the other) leaves the proxy in a state the
operator does not appear to recover from on its own, for however long you
leave it. There is no confirmed mechanism to un-stick a proxy in this state
short of the full recreate below.

A second, related discovery: deleting the k8s-side ProxyGroup / Service
annotations does **not** delete the corresponding Tailscale Service (`svc:`)
objects on the tailnet control plane. Those are a separate resource,
managed via `GET/DELETE
https://api.tailscale.com/api/v2/tailnet/-/vip-services`, and they'll keep
squatting a hostname (forcing fresh device registrations into a `-1` suffix)
until explicitly deleted.

## Proven-safe recovery procedure

Use this if a k8s-operator-managed tailnet proxy is stuck (unreachable,
`NeedsLogin`, or landing on an unwanted `-N` suffixed name). Verified working
live on all six apps, 2026-09-29.

1. **Identify the StatefulSet + Secret** backing the stuck proxy:
   ```bash
   kubectl get statefulset -n tailscale | grep <app>
   kubectl get secret -n tailscale | grep <app>
   ```
2. **Delete both together**, in the same action:
   ```bash
   kubectl delete statefulset ts-<app>-<hash> -n tailscale
   kubectl delete secret ts-<app>-<hash>-0 -n tailscale
   ```
   This cleanly ends that pod's tailnet session. Deleting only one (leaving
   the other) reproduces the stuck state above.
3. **Delete the leftover device record** via the API (cleanup, not a
   blocker for step 4 — a device named `<app>` and one named `<app>-1` don't
   collide, so this can happen before or after step 4 without a race):
   ```bash
   CLIENT_ID=$(kubectl get secret operator-oauth -n tailscale -o jsonpath='{.data.client_id}' | base64 -d)
   CLIENT_SECRET=$(kubectl get secret operator-oauth -n tailscale -o jsonpath='{.data.client_secret}' | base64 -d)
   TOKEN=$(curl -s -X POST "https://api.tailscale.com/api/v2/oauth/token" -d "client_id=$CLIENT_ID" -d "client_secret=$CLIENT_SECRET" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')
   # find the device id first (GET .../tailnet/-/devices, filter by name), then:
   curl -s -X DELETE -H "Authorization: Bearer $TOKEN" "https://api.tailscale.com/api/v2/device/<id>"
   ```
4. **If a `svc:<app>` Tailscale Service object exists** (only relevant if a
   ProxyGroup/Services migration was ever attempted for this app), delete it
   too, or the fresh device will land on a `-1` suffix instead of the plain
   name:
   ```bash
   curl -s -X DELETE -H "Authorization: Bearer $TOKEN" "https://api.tailscale.com/api/v2/tailnet/-/vip-services/svc:<app>"
   ```
5. **Wait for the operator to auto-recreate.** No manual StatefulSet
   creation needed — the operator notices the Service has no proxy and
   provisions a fresh one within ~20-30 seconds. Watch for it:
   ```bash
   kubectl get pods -n tailscale | grep <app>
   ```
6. **Verify with a real connection, not `tailscale serve status`**:
   ```bash
   curl -m 6 "http://<app>.taildd208.ts.net/"
   kubectl logs -n tailscale ts-<app>-<hash>-0 | grep "active login"
   ```

## Still open

- **The daily ~05:00 operator crash itself is not fixed** — it self-heals
  within a minute via normal CrashLoopBackOff, so it's not urgent, but it's
  the same class of CoreDNS-race problem already fixed once for `nut-server`
  on ipc4 (`network-online.target` override — see `docs/` or ask about that
  incident). The operator's Deployment doesn't have an equivalent fix (e.g.
  an initContainer that waits for CoreDNS before starting). Worth doing if
  this keeps causing knock-on effects.
- Whether this daily crash is what caused the *original* stuck-serve-config
  state (as opposed to something else) was never confirmed. If the six apps
  go dark again shortly after a ~05:00 crash with no self-inflicted device
  deletion in between, that would be useful evidence one way or the other.
