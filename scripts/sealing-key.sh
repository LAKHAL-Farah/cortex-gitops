#!/usr/bin/env bash
# Back up / restore the Sealed Secrets controller key, so an ephemeral cluster can be
# rebuilt WITHOUT re-sealing (the committed SealedSecrets stay decryptable).
#   ./scripts/sealing-key.sh backup  [file]    # after the controller first started
#   ./scripts/sealing-key.sh restore [file]    # on a NEW cluster, BEFORE syncing apps/sealed-secrets.yaml
# The file is the PRIVATE key: store it offline (password manager / encrypted USB), never in git.
set -euo pipefail
cd "$(dirname "$0")/.."
NS="${SEALED_SECRETS_NAMESPACE:-sealed-secrets}"
FILE="${2:-$HOME/.cortex/sealing-key.backup.yaml}"
case "$(cd "$(dirname "$FILE")" 2>/dev/null && pwd)/" in
  "$PWD"/*) echo "refusing: $FILE is inside this git repo"; exit 1;; esac
echo "context: $(kubectl config current-context)"
case "${1:-}" in
  backup)
    mkdir -p "$(dirname "$FILE")"; umask 077
    kubectl -n "$NS" get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > "$FILE"
    grep -q 'tls.key' "$FILE" || { rm -f "$FILE"; echo "no sealing key found (is the controller running?)"; exit 1; }
    chmod 600 "$FILE"; echo "saved $FILE  -> copy it somewhere OFFLINE" ;;
  restore)
    [ -f "$FILE" ] || { echo "missing $FILE"; exit 1; }
    kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
    kubectl apply -f "$FILE"
    # If the controller is already running it must reload the key:
    kubectl -n "$NS" delete pod -l app.kubernetes.io/name=sealed-secrets --ignore-not-found
    echo "restored; the controller will pick the key up on start" ;;
  *) echo "usage: $0 backup|restore [file]"; exit 1 ;;
esac
