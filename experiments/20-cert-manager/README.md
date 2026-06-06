# Experiment 20: cert-manager

## What you'll observe

- cert-manager running as cluster infrastructure (installed via Flux from `manifests/cert-manager/`)
- A `ClusterIssuer` with the `selfSigned` backend — no ACME, no external CA required
- A `Certificate` resource that cert-manager resolves into a Kubernetes TLS `Secret`
- Automatic certificate renewal (cert-manager watches `renewBefore` and rotates before expiry)

## Concepts

### What cert-manager does

cert-manager is a Kubernetes controller that manages the full lifecycle of X.509 certificates:

1. You declare a `Certificate` resource (desired state)
2. cert-manager talks to an `Issuer` or `ClusterIssuer` to obtain the cert
3. cert-manager stores the result in a `Secret` of type `kubernetes.io/tls`
4. cert-manager watches expiry and renews automatically before `renewBefore`

### Issuers vs ClusterIssuers

| Resource | Scope | Use case |
|----------|-------|----------|
| `Issuer` | Namespace | Per-team CA; certificates only in that namespace |
| `ClusterIssuer` | Cluster-wide | Shared CA; any namespace can reference it |

This experiment uses a `ClusterIssuer` so any namespace can request certs from it.

### Issuer backends

| Backend | How it works | When to use |
|---------|-------------|-------------|
| `selfSigned` | Signs with its own private key | Internal cluster services, experiments |
| `ca` | Signs with a provided CA cert/key | Internal PKI; share the CA cert with clients |
| `acme` | ACME protocol (Let's Encrypt, etc.) | Public-facing services with a real domain |
| `vault` | HashiCorp Vault PKI | Enterprise PKI |

This experiment uses `selfSigned` — no external dependencies, works entirely in-cluster.

### The Certificate lifecycle

```
Certificate (desired) → cert-manager controller → CertificateRequest → Issuer → Secret (actual)
```

The `Secret` contains three keys:
- `tls.crt` — the certificate (PEM)
- `tls.key` — the private key (PEM)
- `ca.crt` — the issuer CA cert (for selfSigned, same as `tls.crt`)

Pods and Ingress resources reference this Secret directly.

### Relationship to SPIRE (experiment 11)

SPIRE and cert-manager both issue TLS credentials, but at different layers:

- **SPIRE**: workload identity via SVID/SPIFFE — certificate is tied to the workload's identity, not a DNS name; rotated by the SPIRE agent automatically
- **cert-manager**: Kubernetes-native PKI — certificate is a Kubernetes Secret; referenced by pods/ingress via volume mounts or TLS termination

They are complementary: cert-manager is the right tool for Ingress TLS and service-to-service TLS where you want Kubernetes Secrets; SPIRE is the right tool for zero-trust workload attestation.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `cert-demo` namespace |
| `clusterissuer.yaml` | `selfsigned` ClusterIssuer — cluster-wide self-signed CA |
| `certificate.yaml` | `demo-tls` Certificate → `demo-tls-secret` Secret |

## Infrastructure

cert-manager itself is installed via Flux from `manifests/cert-manager/`, which pulls the upstream `cert-manager.yaml` release manifest. The Flux Kustomization is at `clusters/ipc/cert-manager.yaml`.

## Running manually

```
kubectl apply -f experiments/20-cert-manager/namespace.yaml
kubectl apply -f experiments/20-cert-manager/clusterissuer.yaml
kubectl apply -f experiments/20-cert-manager/certificate.yaml

# Watch cert-manager issue the certificate (~5s)
kubectl get certificate demo-tls -n cert-demo --watch

# Inspect the resulting TLS secret
kubectl get secret demo-tls-secret -n cert-demo -o yaml

# Decode the certificate
kubectl get secret demo-tls-secret -n cert-demo -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text
```

## Expected output

```
NAME       READY   SECRET            AGE
demo-tls   True    demo-tls-secret   5s
```

The Secret will contain a self-signed certificate valid for 90 days, with SANs matching the `dnsNames` in the Certificate spec.
