#!/usr/bin/env bash
# Configures Vault PKI intermediate CA and wires it to cert-manager.
#
# Run once from omen after Vault is unsealed. Idempotent on re-runs.
#
# What this does:
#   1. Enables pki_int secrets engine in Vault
#   2. Generates an intermediate CA CSR (key stays in Vault)
#   3. Signs the CSR via cert-manager's internal-ca-issuer (self-signed root)
#   4. Imports the signed cert chain back into Vault
#   5. Creates a 'home-lab' PKI role for *.home.skeptomai.com
#   6. Enables Vault Kubernetes auth
#   7. Creates a cert-manager policy + Kubernetes auth role
#
# After this script: apply manifests/vault-pki/ to create the ClusterIssuer.
set -euo pipefail

VAULT_NS=vault
VAULT_POD=vault-0   # forwards requests to the active HA leader
VAULT_TOKEN=${VAULT_TOKEN:-hvs.K9EVRe383l66Y0zdnXvWnZ5v}
KUBE_HOST=https://kubernetes.default.svc:443

vcmd() {
    kubectl -n "$VAULT_NS" exec "$VAULT_POD" -- \
        env VAULT_TOKEN="$VAULT_TOKEN" VAULT_SKIP_VERIFY=false vault "$@"
}

echo "==> Checking Vault is unsealed..."
SEALED=$(vcmd status -format=json | grep -o '"sealed":[a-z]*' | grep -o '[a-z]*$')
if [ "$SEALED" = "true" ]; then
    echo "ERROR: Vault is sealed. Unseal it first." >&2
    exit 1
fi
echo "    Vault is unsealed."

# ---------------------------------------------------------------------------
echo "==> Enabling PKI intermediate secrets engine..."
vcmd secrets enable -path=pki_int pki 2>/dev/null && echo "    Enabled pki_int." \
    || echo "    pki_int already enabled (skipping)."
vcmd secrets tune -max-lease-ttl=43800h pki_int   # 5 years max

# ---------------------------------------------------------------------------
echo "==> Generating intermediate CA CSR in Vault..."
CSR_PEM=$(vcmd write -field=csr pki_int/intermediate/generate/internal \
    common_name="k3s Intermediate CA" \
    organization="k3s-experiments" \
    key_type=ec key_bits=256 \
    2>/dev/null || \
    # If key already exists, re-export the existing CSR
    vcmd read -field=csr pki_int/intermediate/generate/internal 2>/dev/null || true)

if [ -z "$CSR_PEM" ]; then
    echo "    Intermediate CSR already set (Vault key exists). Skipping CSR generation."
    SKIP_SIGNING=true
else
    SKIP_SIGNING=false
fi

# ---------------------------------------------------------------------------
if [ "$SKIP_SIGNING" = "false" ]; then
    echo "==> Signing CSR with cert-manager internal-ca-issuer..."
    CSR_B64=$(printf '%s' "$CSR_PEM" | base64 -w0)

    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: CertificateRequest
metadata:
  name: vault-pki-intermediate
  namespace: cert-manager
spec:
  isCA: true
  duration: 43800h
  issuerRef:
    name: internal-ca-issuer
    kind: ClusterIssuer
  request: "${CSR_B64}"
EOF

    echo "    Waiting for CertificateRequest to be approved and signed..."
    kubectl -n cert-manager wait certificaterequest/vault-pki-intermediate \
        --for=condition=Ready --timeout=120s

    echo "==> Importing signed intermediate cert into Vault..."
    SIGNED_B64=$(kubectl -n cert-manager get certificaterequest vault-pki-intermediate \
        -o jsonpath='{.status.certificate}')
    CA_B64=$(kubectl -n cert-manager get certificaterequest vault-pki-intermediate \
        -o jsonpath='{.status.ca}')

    # Pipe cert chain via stdin with explicit newline between PEM blocks.
    # printf '%s\n%s\n' preserves the newline that command substitution strips —
    # without it the END/BEGIN markers of consecutive PEM blocks are merged.
    printf '%s\n%s\n' "$(printf '%s' "$SIGNED_B64" | base64 -d)" \
        "$(printf '%s' "$CA_B64" | base64 -d)" | \
        kubectl -n "$VAULT_NS" exec -i "$VAULT_POD" -- sh -c \
        "cat > /tmp/signed.crt && env VAULT_TOKEN=${VAULT_TOKEN} vault write pki_int/intermediate/set-signed certificate=@/tmp/signed.crt"
    echo "    Intermediate CA imported."
fi

# ---------------------------------------------------------------------------
echo "==> Configuring PKI URLs..."
vcmd write pki_int/config/urls \
    issuing_certificates="https://vault.vault.svc:8200/v1/pki_int/ca" \
    crl_distribution_points="https://vault.vault.svc:8200/v1/pki_int/crl"

# ---------------------------------------------------------------------------
echo "==> Creating 'home-lab' PKI role..."
vcmd write pki_int/roles/home-lab \
    allowed_domains="home.skeptomai.com,svc.cluster.local" \
    allow_subdomains=true \
    allow_bare_domains=false \
    allow_wildcard_certificates=true \
    max_ttl=8760h \
    key_type=any \
    require_cn=false

# ---------------------------------------------------------------------------
echo "==> Enabling Vault Kubernetes auth..."
vcmd auth enable kubernetes 2>/dev/null && echo "    Enabled kubernetes auth." \
    || echo "    Kubernetes auth already enabled (skipping)."

vcmd write auth/kubernetes/config kubernetes_host="$KUBE_HOST"

# ---------------------------------------------------------------------------
echo "==> Creating cert-manager PKI policy..."
printf 'path "pki_int/sign/home-lab" { capabilities = ["create","update"] }\npath "pki_int/issue/home-lab" { capabilities = ["create","update"] }\n' | \
    kubectl -n "$VAULT_NS" exec -i "$VAULT_POD" -- sh -c \
    "cat | env VAULT_TOKEN=$VAULT_TOKEN vault policy write cert-manager-pki -"

# ---------------------------------------------------------------------------
echo "==> Creating Kubernetes auth role for cert-manager SA..."
vcmd write auth/kubernetes/role/cert-manager \
    bound_service_account_names=cert-manager \
    bound_service_account_namespaces=cert-manager \
    policies=cert-manager-pki \
    ttl=1h

# ---------------------------------------------------------------------------
echo ""
echo "Vault PKI setup complete."
echo ""
echo "Next steps:"
echo "  kubectl apply -k manifests/vault-pki"
echo "  # Verify issuer:"
echo "  kubectl get clusterissuer vault-pki-issuer"
