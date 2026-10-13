#!/usr/bin/env bash
# Build every kustomization and validate it (and apps/) against Kubernetes schemas.
# Needs: kustomize, kubeconform.
set -euo pipefail
cd "$(dirname "$0")/.."

K8S_VERSION="${K8S_VERSION:-1.31.0}"
CRDS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
KC=(kubeconform -strict -summary -kubernetes-version "$K8S_VERSION"
    -schema-location default -schema-location "$CRDS")

for dir in base overlays/*/; do
  dir="${dir%/}"
  [ -f "$dir/kustomization.yaml" ] || continue
  echo "==> $dir"
  kustomize build "$dir" | "${KC[@]}"
done

echo "==> apps"
"${KC[@]}" apps/*.yaml
