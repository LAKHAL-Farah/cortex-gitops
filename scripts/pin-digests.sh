#!/usr/bin/env bash
# Pin third-party images by digest (postgres, neo4j in base; mailpit in the k3d overlay).
# Needs: crane (go-containerregistry) and yq v4. Review `git diff` before committing.
set -euo pipefail
cd "$(dirname "$0")/.."

pin() { # file image-name registry-ref
  local file="$1" name="$2" ref="$3" d
  d="$(crane digest "$ref")"
  [[ "$d" == sha256:* ]] || { echo "could not resolve $ref"; exit 1; }
  N="$name" D="$d" yq -i '(.images[] | select(.name == env(N))).digest = env(D)' "$file"
  echo "$name -> $d"
}

pin base/kustomization.yaml postgres docker.io/library/postgres:16
pin base/kustomization.yaml neo4j docker.io/library/neo4j:5-community
pin overlays/k3d/kustomization.yaml docker.io/axllent/mailpit docker.io/axllent/mailpit:latest
