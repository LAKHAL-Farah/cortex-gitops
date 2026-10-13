#!/usr/bin/env bash
# Apply the k3d overlay directly (no Argo CD) and wait for the workloads.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=cortex

kubectl apply -k overlays/k3d
kubectl -n "$NS" rollout status statefulset/postgres --timeout=300s
kubectl -n "$NS" rollout status statefulset/neo4j --timeout=300s
kubectl -n "$NS" rollout status deployment/api --timeout=600s
kubectl -n "$NS" rollout status deployment/web --timeout=300s
kubectl -n "$NS" get pods
echo
echo "UI:   http://cortex.localhost:8080   (admin / dev-admin-Passw0rd, you will be asked to change it)"
echo "Mail: http://mail.cortex.localhost:8080"
