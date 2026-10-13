#!/usr/bin/env bash
# Step 7: install a PINNED Argo CD (checksum verified), then hand the cluster over to Git.
# Bump ARGOCD_VERSION and ARGOCD_SHA256 together:
#   curl -sSfL https://raw.githubusercontent.com/argoproj/argo-cd/<ver>/manifests/install.yaml | sha256sum
set -euo pipefail
cd "$(dirname "$0")/.."

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.5}"
ARGOCD_SHA256="${ARGOCD_SHA256:-90dc9094bf4c5964afd9c0e35d735e1c2fcbbda4f8e36799c092d9864ed65f50}"
URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
curl -sSfL "$URL" -o "$tmp"
echo "${ARGOCD_SHA256}  ${tmp}" | sha256sum -c - || { echo "checksum mismatch for ${ARGOCD_VERSION}"; exit 1; }

kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd
# Server-side: the CRDs are too large for client-side apply's annotation.
kubectl apply -n argocd --server-side --force-conflicts -f "$tmp"
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-applicationset-controller --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

kubectl apply -f apps/project.yaml
echo
echo "Argo CD ${ARGOCD_VERSION} is up. Next:"
echo "  kubectl apply -f apps/sealed-secrets.yaml          # controller, from Git"
echo "  OVERLAY=k3d-sealed ./scripts/seal-secrets.sh        # then commit + merge via PR"
echo "  kubectl apply -f apps/cortex-k3d-sealed.yaml        # the LAST manual kubectl apply"
echo
echo "UI:       kubectl -n argocd port-forward svc/argocd-server 9443:443  -> https://localhost:9443"
echo "Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
