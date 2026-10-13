#!/usr/bin/env bash
# Encrypt secrets.env into overlays/azure/sealed-cortex-secrets.yaml (safe to commit).
# Needs: kubectl (pointed at the AKS cluster) and kubeseal, with the
# sealed-secrets controller already running in the cluster.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f secrets.env ] || { echo "create secrets.env from secrets.env.example first"; exit 1; }
# Refuse obviously unfinished input.
for k in CORTEX_DB_PASSWORD CORTEX_NEO4J_PASSWORD CORTEX_API_KEY CORTEX_JWT_SECRET CORTEX_ADMIN_PASSWORD; do
  v="$(grep -E "^${k}=" secrets.env | head -1 | cut -d= -f2-)"
  [ -n "$v" ] || { echo "$k is empty in secrets.env"; exit 1; }
done
# Drop optional keys left empty (they are `optional: true` in the manifests).
grep -Ev '^(#|$)|=$' secrets.env > .secrets.filtered.env
trap 'rm -f .secrets.filtered.env' EXIT

kubectl create secret generic cortex-secrets --namespace cortex \
  --from-env-file=.secrets.filtered.env --dry-run=client -o yaml \
| kubeseal --format yaml \
    --controller-name "${SEALED_SECRETS_NAME:-sealed-secrets}" \
    --controller-namespace "${SEALED_SECRETS_NAMESPACE:-sealed-secrets}" \
    > overlays/azure/sealed-cortex-secrets.yaml

echo "wrote overlays/azure/sealed-cortex-secrets.yaml -> uncomment it in overlays/azure/kustomization.yaml"
