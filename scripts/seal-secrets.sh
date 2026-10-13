#!/usr/bin/env bash
# Encrypt secrets.env into overlays/$OVERLAY/sealed-cortex-secrets.yaml (safe to commit).
# OVERLAY=azure (default) or OVERLAY=k3d-sealed. kubectl must point at the cluster whose
# controller will decrypt it: sealing keys are per cluster.
# Needs: kubectl (pointed at the AKS cluster) and kubeseal, with the
# sealed-secrets controller already running in the cluster.
set -euo pipefail
cd "$(dirname "$0")/.."
OVERLAY="${OVERLAY:-azure}"
[ -d "overlays/$OVERLAY" ] || { echo "no such overlay: $OVERLAY"; exit 1; }

[ -f secrets.env ] || { echo "create secrets.env from secrets.env.example first"; exit 1; }
# Refuse obviously unfinished input.
for k in CORTEX_DB_PASSWORD CORTEX_NEO4J_PASSWORD CORTEX_API_KEY CORTEX_JWT_SECRET CORTEX_ADMIN_PASSWORD COLLECTOR_FALCO_TOKEN; do
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
    > "overlays/$OVERLAY/sealed-cortex-secrets.yaml"

echo "wrote overlays/$OVERLAY/sealed-cortex-secrets.yaml -> uncomment it in overlays/$OVERLAY/kustomization.yaml"

# --- collector-ssh: private key + Ansible inventory (both required) ------------
# Put them in collector-secrets/ (gitignored): id_ed25519 and hosts.ini.
KEY="collector-secrets/id_ed25519"; INV="collector-secrets/hosts.ini"
[ -f "$KEY" ] || { echo "missing $KEY (the SSH key the collector uses on the nodes)"; exit 1; }
[ -f "$INV" ] || { echo "missing $INV (copy of infra/ansible/inventory/hosts.ini)"; exit 1; }
grep -q 'ansible_host=' "$INV" || { echo "$INV has no ansible_host= entries"; exit 1; }

kubectl create secret generic collector-ssh --namespace cortex \
  --from-file=id_ed25519="$KEY" --from-file=hosts.ini="$INV" --dry-run=client -o yaml \
| kubeseal --format yaml \
    --controller-name "${SEALED_SECRETS_NAME:-sealed-secrets}" \
    --controller-namespace "${SEALED_SECRETS_NAMESPACE:-sealed-secrets}" \
    > "overlays/$OVERLAY/sealed-collector-ssh.yaml"

echo "wrote overlays/$OVERLAY/sealed-collector-ssh.yaml -> uncomment it in overlays/$OVERLAY/kustomization.yaml"
