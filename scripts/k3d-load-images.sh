#!/usr/bin/env bash
# Build api/web from a local checkout of the Cortex repo and import them into k3d
# as cortex-api:local / cortex-web:local (what overlays/k3d expects).
set -euo pipefail
CLUSTER="${CLUSTER:-cortex}"
CORTEX_REPO="${CORTEX_REPO:-../Cortex}"

[ -d "$CORTEX_REPO/services/api" ] || { echo "set CORTEX_REPO to your Cortex checkout (got: $CORTEX_REPO)"; exit 1; }

docker build -t cortex-api:local "$CORTEX_REPO/services/api"
docker build -t cortex-web:local "$CORTEX_REPO/services/web"
k3d image import -c "$CLUSTER" cortex-api:local cortex-web:local
