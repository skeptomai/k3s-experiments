# Experiment 20 — cert-manager

cert-manager is a Kubernetes controller that manages the full lifecycle of X.509 certificates as native cluster resources. Rather than generating and distributing certificates manually, you declare a `Certificate` resource and cert-manager handles issuance, Secret population, and automatic renewal before expiry. This experiment demonstrates the core workflow using a self-signed `ClusterIssuer` — no external CA or ACME account required — so the entire PKI lives inside the cluster.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `cert-demo` namespace |
| `clusterissuer.yaml` | `ClusterIssuer` named `selfsigned` using the `selfSigned` backend |
| `certificate.yaml` | `Certificate` for `demo.cert-demo.svc.cluster.local`; 90-day duration, 15-day renewal window, stored in Secret `demo-tls-secret` |

## Apply

```
kubectl apply -f experiments/20-cert-manager/namespace.yaml
kubectl apply -f experiments/20-cert-manager/
```

## Observe

Watch cert-manager issue the certificate and populate the Secret:

```
kubectl get certificate -n cert-demo -w
```

The `READY` column transitions to `True` once the Secret is populated. Inspect the resulting TLS Secret:

```
kubectl get secret demo-tls-secret -n cert-demo -o yaml
```

The Secret contains `tls.crt`, `tls.key`, and `ca.crt`. Decode the certificate to confirm the SANs and validity window:

```
kubectl get secret demo-tls-secret -n cert-demo -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text
```

Check the `CertificateRequest` cert-manager created internally:

```
kubectl get certificaterequest -n cert-demo
```

## Teardown

```
kubectl delete namespace cert-demo
```

The `ClusterIssuer` is cluster-scoped — delete it separately if no longer needed:

```
kubectl delete clusterissuer selfsigned
```
