#!/usr/bin/env bash
# Encrypt secrets.env (+ collector-secrets/) into overlays/$OVERLAY/sealed-*.yaml (safe to commit).
#   OVERLAY=azure (default) or OVERLAY=k3d-sealed ./scripts/seal-secrets.sh
# kubectl must point at the cluster whose sealed-secrets controller will decrypt the result:
# sealing keys are per cluster. Needs: kubectl, kubeseal, controller already running.
set -euo pipefail
cd "$(dirname "$0")/.."
OVERLAY="${OVERLAY:-azure}"
# The azure overlay does not deploy the collector (it stays in the lab), so it needs neither
# collector-ssh nor COLLECTOR_FALCO_TOKEN. Force with SEAL_COLLECTOR_SSH=1 / 0.
if [ -z "${SEAL_COLLECTOR_SSH:-}" ]; then
  [ "$OVERLAY" = azure ] && SEAL_COLLECTOR_SSH=0 || SEAL_COLLECTOR_SSH=1
fi
[ -d "overlays/$OVERLAY" ] || { echo "no such overlay: $OVERLAY"; exit 1; }
for c in kubectl kubeseal; do
  command -v "$c" >/dev/null || { echo "$c not found in PATH"; exit 1; }
done
echo "sealing for overlay '$OVERLAY' against context: $(kubectl config current-context)"
kubectl get --raw /readyz >/dev/null 2>&1 || {
  echo "cluster is unreachable. Is Docker running and the k3d cluster started?"
  echo "  k3d cluster list; k3d cluster start cortex   (then: kubectl get nodes)"
  exit 1
}
kubectl -n "${SEALED_SECRETS_NAMESPACE:-sealed-secrets}" get service "${SEALED_SECRETS_NAME:-sealed-secrets}" >/dev/null 2>&1 || {
  echo "sealed-secrets controller not found. Install it first:"
  echo "  kubectl apply -f apps/sealed-secrets.yaml && kubectl -n sealed-secrets rollout status deploy/sealed-secrets"
  exit 1
}

[ -f secrets.env ] || { echo "create secrets.env from secrets.env.example first"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Files edited on Windows (/mnt/c) have CRLF; a trailing \r would end up inside every secret.
tr -d '\r' < secrets.env > "$work/clean.env"

# Every non-comment line must be KEY=value. A value wrapped onto a second line (or a stray
# token) becomes a bogus key and makes `kubectl create secret` fail with a confusing message.
bad="$(grep -nEv '^[[:space:]]*(#.*)?$|^[A-Za-z_][A-Za-z0-9_]*=' "$work/clean.env" | cut -d: -f1 | paste -sd, - || true)"
if [ -n "$bad" ]; then
  echo "secrets.env: line(s) $bad are not KEY=value. Join them with the previous line or delete them."
  echo "(show them without values: sed -n '<n>p' secrets.env | cut -c1-4)"
  exit 1
fi
dups="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$work/clean.env" | sort | uniq -d | tr -d '=' | paste -sd' ' - || true)"
[ -z "$dups" ] || { echo "secrets.env: duplicate keys: $dups (the last wins in some tools, the first in others; keep one)"; exit 1; }

# Required keys: must be present AND non-empty (a missing key used to exit silently).
missing=()
req="CORTEX_DB_PASSWORD CORTEX_NEO4J_PASSWORD CORTEX_API_KEY CORTEX_JWT_SECRET CORTEX_ADMIN_PASSWORD"
[ "$SEAL_COLLECTOR_SSH" = 1 ] && req="$req COLLECTOR_FALCO_TOKEN"
for k in $req; do
  v="$(grep -E "^${k}=" "$work/clean.env" | head -1 | cut -d= -f2- || true)"
  [ -n "$v" ] || missing+=("$k")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "missing or empty in secrets.env: ${missing[*]}"
  echo "(compare with secrets.env.example; COLLECTOR_FALCO_TOKEN: openssl rand -hex 32)"
  exit 1
fi
# Drop optional keys left empty (they are `optional: true` in the manifests).
grep -Ev '^(#|$)|=$' "$work/clean.env" > "$work/filtered.env"

seal() { # reads a Secret manifest on stdin, writes the SealedSecret to $1 only on success
  kubeseal --format yaml \
    --controller-name "${SEALED_SECRETS_NAME:-sealed-secrets}" \
    --controller-namespace "${SEALED_SECRETS_NAMESPACE:-sealed-secrets}" > "$work/out.yaml"
  [ -s "$work/out.yaml" ] || { echo "kubeseal produced no output"; exit 1; }
  mv "$work/out.yaml" "$1"
}

out="overlays/$OVERLAY/sealed-cortex-secrets.yaml"
kubectl create secret generic cortex-secrets --namespace cortex \
  --from-env-file="$work/filtered.env" --dry-run=client -o yaml | seal "$out"
echo "wrote $out"

# --- collector-ssh: private key + Ansible inventory (both required) ------------
if [ "$SEAL_COLLECTOR_SSH" != 1 ]; then
  echo "skipping collector-ssh (collector not deployed from overlay '$OVERLAY')"
  echo "next: uncomment sealed-cortex-secrets.yaml in overlays/$OVERLAY/kustomization.yaml, then git add it"
  exit 0
fi
# Put them in collector-secrets/ (gitignored): id_ed25519 and hosts.ini.
KEY="collector-secrets/id_ed25519"; INV="collector-secrets/hosts.ini"
[ -f "$KEY" ] || { echo "missing $KEY (the SSH key the collector uses on the nodes)"; exit 1; }
[ -f "$INV" ] || { echo "missing $INV (copy of infra/ansible/inventory/hosts.ini)"; exit 1; }
grep -q 'ansible_host=' "$INV" || { echo "$INV has no ansible_host= entries"; exit 1; }
tr -d '\r' < "$KEY" > "$work/id_ed25519"
tr -d '\r' < "$INV" > "$work/hosts.ini"

out="overlays/$OVERLAY/sealed-collector-ssh.yaml"
kubectl create secret generic collector-ssh --namespace cortex \
  --from-file=id_ed25519="$work/id_ed25519" --from-file=hosts.ini="$work/hosts.ini" \
  --dry-run=client -o yaml | seal "$out"
echo "wrote $out"
echo "next: make sure both files are listed (uncommented, 2-space indent) in overlays/$OVERLAY/kustomization.yaml, then git add them"
