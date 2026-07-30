# Experiment 30: HTTPS Ingress

Demonstrates the full stack from a browser to a pod: MetalLB L2 VIP → Traefik
L7 ingress → load-balanced pods, with a TLS certificate issued by Vault PKI and
trusted by the cluster's internal CA.

## What this exercises

| Layer | Component | What it does |
|-------|-----------|--------------|
| L2 VIP | MetalLB | Announces `192.168.88.240` via ARP on the LAN; delivers TCP to the node whose speaker holds the VIP |
| L7 proxy | Traefik | Terminates TLS, reads `Host:` header, routes to the `hello` Service |
| TLS cert | cert-manager + Vault PKI | `vault-pki-issuer` → Vault `pki_int` → leaf cert for `hello.home.skeptomai.com` |
| App | nginx (3 replicas) | Serves a static page; adds `X-Pod-Name` response header so you can see load balancing |

## Prerequisites

- `manifests/vault-pki/` applied (`vault-pki-issuer` ClusterIssuer must be Ready)
- `internal-ca` root cert installed in your OS trust store (`sudo trust anchor --store internal-ca.crt`)
- MikroTik static DNS: `hello.home.skeptomai.com → 192.168.88.240` (see below)

## Apply

```
kubectl apply -f experiments/30-https-ingress/
```

## DNS

A static DNS entry on the MikroTik points `hello.home.skeptomai.com` at Traefik's
MetalLB VIP. To add it:

```
ssh admin@192.168.88.1 "/ip dns static add name=hello.home.skeptomai.com address=192.168.88.240 comment=k3s-experiment-30"
```

If you'd rather not touch MikroTik, add to `/etc/hosts` on omen instead:
`192.168.88.240  hello.home.skeptomai.com`

## Verify

```
curl -sv https://hello.home.skeptomai.com 2>&1 | grep -E "subject|issuer|HTTP/"
```

Expected output:
```
*  subject: CN=hello.home.skeptomai.com
*  issuer: O=k3s-experiments; CN=k3s Intermediate CA
< HTTP/2 200
```

Open `https://hello.home.skeptomai.com` in a browser — the padlock should be
green (no warning) because the cert chains to `internal-ca`, which you've
installed as a trust anchor.

Reload several times and watch `X-Pod-Name` in the response headers (browser
DevTools → Network → response headers) rotate across the three pod hostnames.

## Certificate chain

```
internal-ca  (self-signed root, 10y, cert-manager/internal-ca-tls Secret)
  └── k3s Intermediate CA  (Vault pki_int, 5y, private key in Vault)
        └── hello.home.skeptomai.com  (leaf, 1y, auto-renewed by cert-manager)
```

cert-manager authenticates to Vault via Kubernetes auth (the `cert-manager` SA
token is exchanged for a short-lived Vault token) — no static secrets anywhere.

## Teardown

```
kubectl delete -f experiments/30-https-ingress/
ssh admin@192.168.88.1 "/ip dns static remove [find name=hello.home.skeptomai.com]"
```
