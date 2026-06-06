# Experiment 21: mTLS with SPIRE SVIDs

## What you'll observe

- Two workloads each receiving a unique X.509 SVID from SPIRE via the Workload API — no secrets, no cert files baked into images
- A TLS server that **requires** a client certificate (`-Verify 1`)
- A client that presents its own SVID as the client cert and verifies the server against the SPIRE trust bundle
- Both sides print their SPIFFE ID and the peer's SPIFFE ID, showing the full mutual authentication

## Why this closes the loop on experiment 11

Experiment 11 showed that a workload can *get* an SVID. This experiment shows what you actually *do* with one: use it to authenticate to another service over TLS, without any pre-shared secrets or manual cert distribution. The identity of each workload is derived purely from attestation — SPIRE verifies the pod's Kubernetes identity and issues the cert accordingly.

## Concepts

### mTLS vs TLS

Standard TLS: the client verifies the server's certificate. The server doesn't know who the client is.

Mutual TLS (mTLS): both sides present a certificate. The server verifies the client, and the client verifies the server. Both are authenticated.

```
Client                              Server
  |------ ClientHello ─────────────►|
  |◄───── ServerHello + cert ────────|
  |------ client cert ──────────────►|   ← this is what makes it mutual
  |◄───── Finished ──────────────────|
  |       (both sides verified)      |
```

### How SPIRE enables zero-secret mTLS

In traditional mTLS, you have to distribute client and server certificates ahead of time — a secret management problem. SPIRE eliminates that:

1. The SPIRE agent attests the workload (verifies it is the pod it claims to be)
2. The agent issues an SVID — a short-lived X.509 cert tied to the workload's SPIFFE ID
3. Both workloads use their SVIDs as their TLS certificates
4. Both verify their peer against the SPIRE trust bundle (the CA cert)

No secrets are deployed. No cert files are baked into images. Identity is attestation-derived.

### Why the trust bundle is enough for verification

Both SVIDs are signed by the same SPIRE CA (trust domain `ipc.local`). The trust bundle (`bundle.0.pem`) is that CA's certificate. When the client verifies the server's cert against the bundle, it is asking: "was this cert signed by the SPIRE CA I trust?" If yes, the cert is genuine — SPIRE only issues SVIDs to attested workloads.

### SPIFFE ID in the SAN

SVIDs carry the workload's SPIFFE ID in the X.509 Subject Alternative Name as a URI:

```
URI:spiffe://ipc.local/mtls-server
URI:spiffe://ipc.local/mtls-client
```

A SPIFFE-aware client would extract this URI and apply authorization policy ("am I allowed to talk to `spiffe://ipc.local/mtls-server`?"). In this experiment `openssl s_client` does the chain verification but not URI-based authorization — the README covers why in the "what this doesn't do" section below.

### What this experiment uses instead of spiffe-helper

Production deployments typically use [spiffe-helper](https://github.com/spiffe/spiffe-helper) as a sidecar: it watches the Workload API, writes certs to disk, and refreshes them before expiry. This experiment uses a simpler init-container pattern — the SVID is fetched once at startup and used for the duration of the pod's life. For a 1-hour SVID TTL this is fine for a demo; for long-lived services, spiffe-helper or a SPIFFE-aware library is the right choice.

### What this experiment doesn't do

- **URI SAN authorization**: `openssl s_client` verifies the cert chain but does not enforce which SPIFFE IDs are allowed to connect. A real service would check the peer's SPIFFE ID against an allowlist after the TLS handshake.
- **Automatic cert rotation**: the init-container approach fetches once. spiffe-helper or the go-spiffe library handles rotation.
- **Envoy / service mesh**: a transparent sidecar proxy (Envoy + SPIRE) can add mTLS to any service without code changes. This experiment does it explicitly to show the mechanics.

## Architecture

```
mtls-demo namespace

mtls-server (Deployment)          mtls-client (Pod)
  serviceAccount: mtls-server-sa    serviceAccount: mtls-client-sa
  SPIFFE ID: spiffe://ipc.local/mtls-server
                                    SPIFFE ID: spiffe://ipc.local/mtls-client
  init: fetch SVID → /certs         init: fetch SVID → /certs
  main: openssl s_server :8443      main: openssl s_client → mtls-server-svc:8443
        -Verify 1 (require          presents /certs/svid.0.pem as client cert
         client cert)               verifies server against /certs/bundle.0.pem

        ◄──────── mTLS ──────────►
        both sides authenticated
        via SPIRE-issued SVIDs
```

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `mtls-demo` namespace, `mtls-server-sa` and `mtls-client-sa` service accounts |
| `registration-job.yaml` | Registers `spiffe://ipc.local/mtls-server` and `spiffe://ipc.local/mtls-client` in SPIRE (reuses `spire-registrar` SA from exp 11) |
| `server.yaml` | `mtls-server` Deployment + `mtls-server-svc` Service |
| `client.yaml` | `mtls-client` one-shot Pod |

## Running manually

```
kubectl apply -f experiments/21-mtls-spire/namespace.yaml
kubectl apply -f experiments/21-mtls-spire/registration-job.yaml
```

Wait for the registration job to complete:

```
kubectl wait --for=condition=complete job/spire-register-mtls -n spire --timeout=60s
```

Then apply the server and wait for it to be ready:

```
kubectl apply -f experiments/21-mtls-spire/server.yaml
kubectl rollout status deployment/mtls-server -n mtls-demo
```

Then run the client:

```
kubectl apply -f experiments/21-mtls-spire/client.yaml
kubectl logs mtls-client -n mtls-demo -c client --follow
```

## Expected output (client logs)

```
=== Client identity ===
            URI:spiffe://ipc.local/mtls-client

=== Connecting to mtls-server-svc:8443 ===
CONNECTED(00000003)
SSL handshake has read ... bytes
Verify return code: 0 (ok)

=== Server SPIFFE ID (from peer certificate) ===
            URI:spiffe://ipc.local/mtls-server

=== mTLS handshake complete: both sides authenticated via SPIRE SVIDs ===
```

`Verify return code: 0 (ok)` means the client validated the server's SVID against the trust bundle. The server logged the client's cert verification on its side. Both identities were derived from SPIRE attestation — no secrets were distributed.
