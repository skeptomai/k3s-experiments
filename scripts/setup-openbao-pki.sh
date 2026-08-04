#!/usr/bin/env bash
# Configures OpenBao PKI intermediate CA and wires it to cert-manager.
#
# Run once from omen after OpenBao is unsealed (it auto-unseals via the
# nazgul Transit satellite -- see k3s-experiments#13 -- so this is normally
# just "run it"). Idempotent on re-runs.
#
# What this does:
#   1. Enables pki_int secrets engine in OpenBao
#   2. Generates an intermediate CA CSR (key stays in OpenBao, never exported)
#   3. Signs the CSR via cert-manager's internal-ca-issuer (self-signed root --
#      the SAME root the old Vault-issued intermediate chained to, so trust
#      doesn't change, only which backend issues the intermediate)
#   4. Imports the signed cert chain back into OpenBao
#   5. Creates a 'home-lab' PKI role for *.home.skeptomai.com
#   6. Enables OpenBao Kubernetes auth
#   7. Creates a cert-manager policy + Kubernetes auth role
#
# After this script, either:
#   - stand up a throwaway ClusterIssuer to validate issuance in isolation
#     (recommended first -- see k3s-experiments#13 Stage 3), or
#   - once validated, cut the real vault-pki-issuer ClusterIssuer over
#     (manifests/vault-pki/clusterissuer.yaml, Stage 4).
set -euo pipefail

OPENBAO_NS=openbao
OPENBAO_POD=openbao-0   # forwards requests to the active HA leader
: "${BAO_TOKEN:?Set BAO_TOKEN to the OpenBao root token before running this script}"
KUBE_HOST=https://kubernetes.default.svc:443

bcmd() {
    kubectl -n "$OPENBAO_NS" exec "$OPENBAO_POD" -- \
        env BAO_TOKEN="$BAO_TOKEN" BAO_SKIP_VERIFY=false bao "$@"
}

echo "==> Checking OpenBao is unsealed..."
SEALED=$(bcmd status -format=json | grep -o '"sealed":[a-z]*' | grep -o '[a-z]*$')
if [ "$SEALED" = "true" ]; then
    echo "ERROR: OpenBao is sealed. Check the nazgul Transit satellite is reachable/unsealed." >&2
    exit 1
fi
echo "    OpenBao is unsealed."

# ---------------------------------------------------------------------------
echo "==> Enabling PKI intermediate secrets engine..."
bcmd secrets enable -path=pki_int pki 2>/dev/null && echo "    Enabled pki_int." \
    || echo "    pki_int already enabled (skipping)."
bcmd secrets tune -max-lease-ttl=43800h pki_int   # 5 years max

# ---------------------------------------------------------------------------
echo "==> Generating intermediate CA CSR in OpenBao..."
CSR_PEM=$(bcmd write -field=csr pki_int/intermediate/generate/internal \
    common_name="k3s OpenBao Intermediate CA" \
    organization="k3s-experiments" \
    key_type=ec key_bits=256 \
    2>/dev/null || \
    # If key already exists, re-export the existing CSR
    bcmd read -field=csr pki_int/intermediate/generate/internal 2>/dev/null || true)

if [ -z "$CSR_PEM" ]; then
    echo "    Intermediate CSR already set (OpenBao key exists). Skipping CSR generation."
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
  name: openbao-pki-intermediate
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
    kubectl -n cert-manager wait certificaterequest/openbao-pki-intermediate \
        --for=condition=Ready --timeout=120s

    echo "==> Importing signed intermediate cert into OpenBao..."
    SIGNED_B64=$(kubectl -n cert-manager get certificaterequest openbao-pki-intermediate \
        -o jsonpath='{.status.certificate}')
    CA_B64=$(kubectl -n cert-manager get certificaterequest openbao-pki-intermediate \
        -o jsonpath='{.status.ca}')

    # Pipe cert chain via stdin with explicit newline between PEM blocks.
    # printf '%s\n%s\n' preserves the newline that command substitution strips —
    # without it the END/BEGIN markers of consecutive PEM blocks are merged.
    printf '%s\n%s\n' "$(printf '%s' "$SIGNED_B64" | base64 -d)" \
        "$(printf '%s' "$CA_B64" | base64 -d)" | \
        kubectl -n "$OPENBAO_NS" exec -i "$OPENBAO_POD" -- sh -c \
        "cat > /tmp/signed.crt && env BAO_TOKEN=${BAO_TOKEN} bao write pki_int/intermediate/set-signed certificate=@/tmp/signed.crt"
    echo "    Intermediate CA imported."
fi

# ---------------------------------------------------------------------------
echo "==> Configuring PKI URLs..."
bcmd write pki_int/config/urls \
    issuing_certificates="https://openbao.openbao.svc:8200/v1/pki_int/ca" \
    crl_distribution_points="https://openbao.openbao.svc:8200/v1/pki_int/crl"

# ---------------------------------------------------------------------------
echo "==> Creating 'home-lab' PKI role..."
bcmd write pki_int/roles/home-lab \
    allowed_domains="home.skeptomai.com,svc.cluster.local" \
    allow_subdomains=true \
    allow_bare_domains=false \
    allow_wildcard_certificates=true \
    max_ttl=8760h \
    key_type=any \
    require_cn=false

# ---------------------------------------------------------------------------
echo "==> Enabling OpenBao Kubernetes auth..."
bcmd auth enable kubernetes 2>/dev/null && echo "    Enabled kubernetes auth." \
    || echo "    Kubernetes auth already enabled (skipping)."

bcmd write auth/kubernetes/config kubernetes_host="$KUBE_HOST"

# ---------------------------------------------------------------------------
echo "==> Creating cert-manager PKI policy..."
printf 'path "pki_int/sign/home-lab" { capabilities = ["create","update"] }\npath "pki_int/issue/home-lab" { capabilities = ["create","update"] }\n' | \
    kubectl -n "$OPENBAO_NS" exec -i "$OPENBAO_POD" -- sh -c \
    "cat | env BAO_TOKEN=$BAO_TOKEN bao policy write cert-manager-pki -"

# ---------------------------------------------------------------------------
echo "==> Creating Kubernetes auth role for cert-manager SA..."
bcmd write auth/kubernetes/role/cert-manager \
    bound_service_account_names=cert-manager \
    bound_service_account_namespaces=cert-manager \
    policies=cert-manager-pki \
    ttl=1h

# ---------------------------------------------------------------------------
echo ""
echo "OpenBao PKI setup complete."
echo ""
echo "Next: validate with a throwaway ClusterIssuer before cutting over the"
echo "real vault-pki-issuer (k3s-experiments#13 Stage 3/4)."
