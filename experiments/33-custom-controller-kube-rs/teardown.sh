#!/usr/bin/env bash
# Tears down the stamp-controller experiment. Deletes any Stamp objects first
# so the finalizer cleanup runs (and its ConfigMaps are removed) before the
# namespace/CRD/RBAC go away. Idempotent — safe to re-run.
#
# Run from omen: bash experiments/33-custom-controller-kube-rs/teardown.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> deleting any Stamp objects (triggers finalizer cleanup)"
kubectl -n custom-controller-demo delete stamp --all --timeout=60s --ignore-not-found=true 2>/dev/null || true

echo "==> deleting controller Deployment"
kubectl delete -f manifests/deployment.yaml --ignore-not-found=true

echo "==> deleting RBAC"
kubectl delete -f manifests/rbac.yaml --ignore-not-found=true

echo "==> deleting CRD (also removes any remaining Stamp objects)"
kubectl delete -f manifests/crd.yaml --ignore-not-found=true

echo "==> deleting namespace"
kubectl delete -f manifests/namespace.yaml --ignore-not-found=true

echo "==> done"
