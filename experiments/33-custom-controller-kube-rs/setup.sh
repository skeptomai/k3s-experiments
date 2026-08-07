#!/usr/bin/env bash
# Deploys the stamp-controller experiment: namespace, CRD, RBAC, and the
# controller Deployment. Idempotent — safe to re-run.
#
# Assumes the stamp-controller image has already been built and pushed to
# 192.168.89.2:5004/stamp-controller:latest (see build-job.yaml / README.md).
#
# Run from omen: bash experiments/33-custom-controller-kube-rs/setup.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> applying namespace"
kubectl apply -f manifests/namespace.yaml

echo "==> applying CRD (Stamp, edu.k3s-experiments.dev/v1alpha1)"
kubectl apply -f manifests/crd.yaml
kubectl wait --for=condition=Established --timeout=30s crd/stamps.edu.k3s-experiments.dev

echo "==> applying RBAC"
kubectl apply -f manifests/rbac.yaml

echo "==> applying controller Deployment"
kubectl apply -f manifests/deployment.yaml

echo "==> waiting for controller rollout"
kubectl -n custom-controller-demo rollout status deployment/stamp-controller --timeout=120s

echo "==> done. Apply a sample Stamp with:"
echo "    kubectl apply -f manifests/sample-stamp.yaml"
