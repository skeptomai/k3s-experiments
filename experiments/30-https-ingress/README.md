# Experiment 30 — HTTPS Ingress

This experiment demonstrates the full browser-to-pod TLS stack on the cluster: MetalLB announces the Traefik VIP via L2 ARP, Traefik terminates TLS and routes by hostname, and cert-manager automatically provisions a leaf certificate from Vault's intermediate CA. Together these three components — MetalLB, Traefik, and Vault PKI — show how a workload gets a trusted HTTPS endpoint without any static secrets or manual certificate management.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `https-demo` namespace |
| `configmap.yaml` | nginx config and HTML page (adds `X-Pod-Name` response header) |
| `deployment.yaml` | 3-replica nginx deployment serving the static page |
| `service.yaml` | ClusterIP Service exposing the nginx pods on port 80 |
| `ingress.yaml` | Traefik Ingress rule for `hello.home.skeptomai.com` with TLS |
| `certificate.yaml` | cert-manager Certificate requesting a leaf cert from `vault-pki-issuer` |

## Prerequisites

- `manifests/vault-pki/` applied — the `vault-pki-issuer` ClusterIssuer must be Ready
- Internal CA trusted on omen: `sudo trust anchor --store internal-ca.crt`
- MikroTik static DNS entry pointing `hello.home.skeptomai.com` at `192.168.88.240` (Traefik's MetalLB VIP)

To add the DNS entry via MikroTik SSH:

```
ssh admin@192.168.88.1 "/ip dns static add name=hello.home.skeptomai.com address=192.168.88.240 comment=k3s-experiment-30"
```

Alternatively, add `192.168.88.240  hello.home.skeptomai.com` to `/etc/hosts` on omen.

## Apply

```
kubectl apply -f experiments/30-https-ingress/
```

cert-manager will request a certificate from Vault immediately after the Certificate resource is created. Check readiness with:

```
kubectl get certificate -n https-demo hello-tls
```

## Observe

1. Confirm the certificate was issued:

```
kubectl describe certificate -n https-demo hello-tls
```

Look for `Status: True, Type: Ready` and the issuer chain showing `k3s Intermediate CA`.

2. Verify TLS and HTTP response from omen:

```
curl -sv https://hello.home.skeptomai.com 2>&1 | grep -E "subject|issuer|HTTP/"
```

Expected output:
```
*  subject: CN=hello.home.skeptomai.com
*  issuer: O=k3s-experiments; CN=k3s Intermediate CA
< HTTP/2 200
```

3. Open `https://hello.home.skeptomai.com` in a browser — the padlock should show no warning because the cert chains to `internal-ca`. In DevTools → Network → response headers, reload several times and watch `X-Pod-Name` rotate across the three pod names.

## Teardown

```
kubectl delete -f experiments/30-https-ingress/
```

Remove the MikroTik DNS entry if added:

```
ssh admin@192.168.88.1 "/ip dns static remove [find name=hello.home.skeptomai.com]"
```
