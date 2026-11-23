#!/usr/bin/env bash
# Remove the throwaway namespace (VMI, Secret, launcher pod).
set -euo pipefail
kubectl delete namespace kata-secret-test --wait=false
