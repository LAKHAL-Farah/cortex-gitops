#!/usr/bin/env bash
# Create the local rehearsal cluster. Host :8080 -> Traefik (cortex.localhost:8080).
set -euo pipefail
CLUSTER="${CLUSTER:-cortex}"

if k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
  echo "cluster '$CLUSTER' already exists"
else
  k3d cluster create "$CLUSTER" --agents 1 -p "8080:80@loadbalancer" --wait
fi
kubectl config use-context "k3d-$CLUSTER"
kubectl get nodes
