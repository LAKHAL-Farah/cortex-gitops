#!/usr/bin/env bash
# Step 5 check: can the cluster pull the CI-built image from GHCR by digest?
# Usage: ./scripts/k3d-pull-test.sh sha256:<digest> [api|web]
# Packages must be public (no imagePullSecret). If this prints ImagePullBackOff /
# 401 / 403 the package is private: make it public or create an imagePullSecret.
set -euo pipefail
DIGEST="${1:?usage: $0 sha256:<digest> [api|web]}"
SVC="${2:-api}"
IMAGE="ghcr.io/lakhal-farah/cortex-${SVC}@${DIGEST}"
NAME="pull-test-$RANDOM"

kubectl run "$NAME" --image="$IMAGE" --restart=Never --command \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}}}' \
  -- true >/dev/null
trap 'kubectl delete pod "$NAME" --ignore-not-found --wait=false >/dev/null' EXIT

for _ in $(seq 1 60); do
  reason="$(kubectl get pod "$NAME" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)"
  case "$reason" in
    Completed|Error) echo "OK: image pulled and started ($IMAGE)"; exit 0 ;;
    ErrImagePull|ImagePullBackOff) kubectl describe pod "$NAME" | tail -15; echo "FAIL: cannot pull $IMAGE"; exit 1 ;;
  esac
  sleep 3
done
echo "timeout waiting for the pod"; kubectl describe pod "$NAME" | tail -15; exit 1
