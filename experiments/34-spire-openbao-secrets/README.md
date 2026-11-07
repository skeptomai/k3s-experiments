# Experiment 34 — SPIRE JWT-SVID → OpenBao Secret Retrieval

This experiment demonstrates the full chain described in `docs/spire-concepts.md`'s
"OpenBao authentication" case (previously only a documented possibility, not
configured anywhere in this cluster): a workload fetches a **JWT-SVID** from SPIRE,
presents it to OpenBao as a Bearer-style login, OpenBao verifies the signature
against SPIRE's own JWT-signing keys and maps the SPIFFE ID (the JWT's `sub` claim)
to an internal role, and — only if that all checks out — returns a real secret. No
static API key or password is ever given to the workload; its only credential is the
identity SPIRE already attested.

This is the JWT counterpart to experiment 21 (`21-mtls-spire`), which showed the
X.509-SVID / mTLS side of SPIRE-issued identity. Together they cover both SVID forms
described in `docs/spire-concepts.md`.

**Important scope note:** this experiment deploys its **own throwaway, dev-mode
OpenBao instance** (`openbao-demo`, in the new `spire-openbao-demo` namespace) — it
does **not** touch the real in-cluster 3-node HA OpenBao (namespace `openbao`) or its
production secrets. No root token, Shamir keys, or transit-seal material from the
real deployment is needed or used anywhere here.

## How it works

1. **`registration-and-jwks-job`** (runs in the `spire` namespace, reusing the
   existing `spire-registrar` ServiceAccount from experiment 11):
   - Registers `spiffe://ipc.local/openbao-client` with selectors matching the
     client pod's namespace + ServiceAccount (standard SPIRE registration, same
     pattern as experiment 21).
   - Fetches SPIRE's full trust bundle (`spire-server bundle show -format spiffe`),
     which contains both `x509-svid` keys (for mTLS, with cert chains) and
     `jwt-svid` keys (bare JWK, used to sign JWT-SVIDs). Filters down to just the
     `jwt-svid` entries and reshapes them into a standard JWKS document (`{"keys":
     [...]}`, with `use` remapped from SPIFFE's `jwt-svid` to the standard `sig`).
   - Publishes that JWKS as a ConfigMap (`spire-jwks`) in `spire-openbao-demo`.

2. **`spire-jwks-server`** — a tiny busybox-httpd Deployment serving that ConfigMap
   over plain HTTP (`spire-jwks-svc:8080/keys.json`), mirroring the existing
   `spire-bundle-signing` pattern already used elsewhere in this cluster to publish
   a SPIRE-derived artifact over HTTP for another component to fetch.

3. **`openbao-demo`** — the throwaway dev-mode OpenBao instance (fixed root token
   `demo-root-token`, no persistence, no TLS — none of that matters for what this is
   demonstrating).

4. **`openbao-configure`** job — configures OpenBao:
   - Enables KV v2 at `secret/` and writes one demo secret,
     `secret/demo/myapp` (`username=demo-app-user`, `password=demo-s3cr3t-value` —
     obviously fake, this is the thing the workload will retrieve).
   - Enables the `jwt` auth method, pointed at `spire-jwks-svc` as its `jwks_url`.
   - Writes a policy (`openbao-demo-policy`) granting read-only access to exactly
     that one secret path.
   - Writes a role (`openbao-demo-role`) that only accepts a JWT whose `aud` claim
     is `openbao-demo` and whose `sub` claim is **exactly**
     `spiffe://ipc.local/openbao-client` — any other SPIFFE ID, or a token for a
     different audience, is rejected.

5. **`openbao-client`** pod — the actual demonstration:
   - Init container fetches a JWT-SVID via the Workload API
     (`spire-agent api fetch jwt -audience openbao-demo`), exactly as
     `docs/spire-concepts.md` describes.
   - Main container prints the SPIFFE ID and decoded JWT claims, then performs the
     real HTTP exchange: `POST /v1/auth/jwt/login` with the JWT, extracts the
     `client_token` OpenBao returns, and uses that token to `GET` the secret.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `spire-openbao-demo` namespace, the `openbao-client-sa` ServiceAccount, and a Role/RoleBinding granting the existing `spire-registrar` SA permission to write a ConfigMap here |
| `registration-and-jwks-job.yaml` | Registers the SPIFFE ID and publishes the JWT-SVID signing keys as a JWKS ConfigMap |
| `jwks-server.yaml` | Serves that ConfigMap over HTTP for OpenBao to fetch |
| `openbao-demo.yaml` | The throwaway dev-mode OpenBao instance |
| `openbao-config-job.yaml` | Configures OpenBao's jwt auth method, role, policy, and demo secret |
| `client.yaml` | The workload: fetches its SVID, logs into OpenBao with it, retrieves the secret |

## Apply

Order matters — later steps depend on earlier ones having actually completed, not
just been submitted:

```
kubectl apply -f experiments/34-spire-openbao-secrets/namespace.yaml
kubectl apply -f experiments/34-spire-openbao-secrets/registration-and-jwks-job.yaml
kubectl wait -n spire job/spire-register-openbao-demo --for=condition=complete --timeout=120s
kubectl apply -f experiments/34-spire-openbao-secrets/jwks-server.yaml
kubectl apply -f experiments/34-spire-openbao-secrets/openbao-demo.yaml
kubectl wait -n spire-openbao-demo deploy/openbao-demo --for=condition=available --timeout=60s
kubectl apply -f experiments/34-spire-openbao-secrets/openbao-config-job.yaml
kubectl wait -n spire-openbao-demo job/openbao-configure --for=condition=complete --timeout=120s
kubectl apply -f experiments/34-spire-openbao-secrets/client.yaml
```

## Observe

1. Confirm registration + JWKS publication:

   ```
   kubectl logs -n spire job/spire-register-openbao-demo
   ```

   Should show the new entry, the extracted JWKS document, and the ConfigMap apply.

2. Confirm OpenBao was configured correctly:

   ```
   kubectl logs -n spire-openbao-demo job/openbao-configure
   ```

3. Watch the actual demonstration:

   ```
   kubectl logs -n spire-openbao-demo openbao-client -c fetch-svid
   kubectl logs -n spire-openbao-demo openbao-client -c client
   ```

   The `fetch-svid` log confirms a JWT-SVID was issued for
   `spiffe://ipc.local/openbao-client`. The `client` log shows, in order: the
   decoded JWT claims (`sub`, `aud`, `exp`), the raw `POST /v1/auth/jwt/login`
   call and OpenBao's response (`client_token` + granted policies), and finally
   the actual secret (`demo-app-user` / `demo-s3cr3t-value`) read back using that
   token.

4. **Prove the scoping is real, not just "it happened to work":**

   ```
   kubectl run openbao-probe --rm -it --restart=Never -n spire-openbao-demo \
     --image=docker.io/library/ubuntu:22.04 --command -- bash -c '
       curl -s -X POST http://openbao-demo-svc:8200/v1/auth/jwt/login \
         -d "{\"role\":\"openbao-demo-role\",\"jwt\":\"not-a-real-jwt\"}"'
   ```

   Should return an auth error — OpenBao is actually checking the signature, not
   rubber-stamping anything presented to it.

## Teardown

```
kubectl delete namespace spire-openbao-demo
kubectl delete -n spire job/spire-register-openbao-demo
```

(The `spire-registrar` ServiceAccount/Role in the `spire` namespace is shared
infrastructure from experiment 11 — don't delete it, other experiments use it too.)
