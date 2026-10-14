#!/usr/bin/env bash
# rollout-check.sh: check every remaining rollout step, and (with --fix) do what can be done.
#
#   ./scripts/rollout-check.sh                  # read-only report for stages: k3d lab
#   ./scripts/rollout-check.sh --fix            # also fix what it safely can (asks before risky steps)
#   ./scripts/rollout-check.sh --fix --yes      # no prompts (still never merges a PR)
#   ./scripts/rollout-check.sh azure            # stages: k3d | lab | azure | all
#
# Environment (all optional):
#   CTX=k3d-cortex  OVERLAY=k3d-sealed  CORTEX_REPO=../Cortex
#   NODES="10.0.1.4 10.0.1.6 10.0.1.7"  TRIVY_HOSTS=controller,storage
#   AKS_CTX=<kubectl context of the AKS cluster>   (needed for the azure stage)
#   RESEAL=1   force re-sealing even if the sealed files exist
#
# Safe to re-run: every step checks first and only acts when something is missing.
# It never merges a PR, never prints secret values, never commits on main.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

FIX=0; YES=0; STAGES=()
for a in "$@"; do
  case "$a" in
    --fix) FIX=1 ;;
    --yes|-y) YES=1 ;;
    -h|--help) usage; exit 0 ;;
    k3d|lab|azure) STAGES+=("$a") ;;
    all) STAGES+=(k3d lab azure) ;;
    *) echo "unknown argument: $a"; usage; exit 2 ;;
  esac
done
[ ${#STAGES[@]} -gt 0 ] || STAGES=(k3d lab)

CTX="${CTX:-k3d-cortex}"
OVERLAY="${OVERLAY:-k3d-sealed}"
CORTEX_REPO="${CORTEX_REPO:-../Cortex}"
NODES="${NODES:-10.0.1.4 10.0.1.6 10.0.1.7}"
TRIVY_HOSTS="${TRIVY_HOSTS:-controller,storage}"
AKS_CTX="${AKS_CTX:-}"
KEY="collector-secrets/id_ed25519"
INV="collector-secrets/hosts.ini"
REQ_KEYS="CORTEX_DB_PASSWORD CORTEX_NEO4J_PASSWORD CORTEX_API_KEY CORTEX_JWT_SECRET CORTEX_ADMIN_PASSWORD COLLECTOR_FALCO_TOKEN"

PASS=0; WARN=0; FAIL=0; TODO=()
ok()     { echo "  [ok]    $*"; PASS=$((PASS+1)); }
bad()    { echo "  [FAIL]  $*"; FAIL=$((FAIL+1)); }
warn()   { echo "  [warn]  $*"; WARN=$((WARN+1)); }
manual() { echo "  [TODO]  $*"; TODO+=("$*"); }
fixed()  { echo "  [fixed] $*"; }
section(){ echo; echo "== $* =="; }
fixing() { [ "$FIX" = 1 ]; }
have()   { command -v "$1" >/dev/null 2>&1; }
confirm(){ [ "$YES" = 1 ] && return 0; local a; read -r -p "          $1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
kc()     { kubectl --context "$CTX" "$@"; }

wait_for() { # wait_for <seconds> <cmd...>
  local t=$1 end; shift; end=$((SECONDS+t))
  while [ "$SECONDS" -lt "$end" ]; do "$@" >/dev/null 2>&1 && return 0; sleep 5; done
  return 1
}
env_get() { tr -d '\r' < secrets.env | grep -E "^$1=" | head -1 | cut -d= -f2-; }
env_set() { # key value (values here are hex, so '|' is safe in sed)
  tr -d '\r' < secrets.env > secrets.env.tmp && mv secrets.env.tmp secrets.env
  if grep -qE "^$1=" secrets.env; then sed -i "s|^$1=.*|$1=$2|" secrets.env; else echo "$1=$2" >> secrets.env; fi
}
app_state() { kc -n argocd get app "$1" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null; }
app_msgs()  { kc -n argocd get app "$1" -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' 2>/dev/null | cut -c1-300; }
with_ctx()  { # with_ctx <context> <cmd...>: run with kubectl's current-context switched, then restore
  local want=$1 prev rc; shift
  prev="$(kubectl config current-context 2>/dev/null)"
  kubectl config use-context "$want" >/dev/null 2>&1 || return 1
  "$@"; rc=$?
  [ -n "$prev" ] && kubectl config use-context "$prev" >/dev/null 2>&1
  return $rc
}
# uncomment/normalise "- <file>" in a kustomization (keeps 2-space list indent)
enable_resource() { # enable_resource <kustomization> <file>
  grep -qE "^  - $2\$" "$1" && return 0
  sed -i -E "s|^[[:space:]]*#?[[:space:]]*-[[:space:]]*$2[[:space:]]*\$|  - $2|" "$1"
  grep -qE "^  - $2\$" "$1"
}

CLUSTER_OK=0; SS_READY=0

# ----------------------------------------------------------------------------------------
stage_k3d() {
  section "A. k3d rehearsal ($CTX, overlay $OVERLAY)"

  echo "- tools"
  for c in kubectl kubeseal git openssl; do have "$c" && ok "$c" || bad "$c not in PATH"; done
  for c in ssh ssh-keygen; do have "$c" && ok "$c" || warn "$c not in PATH (lab stage needs it)"; done
  for c in kustomize kubeconform; do have "$c" && ok "$c" || warn "$c not in PATH (validate.sh will be skipped)"; done

  echo "- cluster"
  if have kubectl && kc get --raw /readyz >/dev/null 2>&1; then
    ok "context $CTX reachable"; CLUSTER_OK=1
  else
    bad "context $CTX unreachable"
    if fixing && have k3d && confirm "run 'k3d cluster start cortex'?"; then
      k3d cluster start cortex && kc get --raw /readyz >/dev/null 2>&1 && { CLUSTER_OK=1; fixed "cluster started"; }
    else
      manual "start Docker + the cluster: k3d cluster list; k3d cluster start cortex  (or ./scripts/k3d-up.sh for a new one)"
    fi
  fi

  if [ "$CLUSTER_OK" = 1 ]; then
    echo "- Argo CD"
    if ! kc get ns argocd >/dev/null 2>&1; then
      bad "argocd namespace missing"
      fixing && confirm "run ./scripts/argocd-install.sh?" && ./scripts/argocd-install.sh && fixed "Argo CD installed"
    else
      local notready=0 w
      for w in deploy/argocd-server deploy/argocd-repo-server deploy/argocd-applicationset-controller statefulset/argocd-application-controller; do
        if [ "$(kc -n argocd get "$w" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ]; then
          ok "$w ready"
        else
          bad "$w not ready (slow image pulls in WSL are common; redis must finish first)"; notready=1
        fi
      done
      if [ "$notready" = 1 ] && fixing; then
        echo "          waiting up to 5 min..."
        wait_for 300 kc -n argocd rollout status deploy/argocd-server --timeout=5s && fixed "Argo CD became ready"
      fi
    fi

    echo "- AppProject 'cortex'"
    if kc -n argocd get appproject cortex >/dev/null 2>&1; then ok "exists"
    else
      bad "missing (apps fail with 'project cortex does not exist')"
      fixing && kc apply -f apps/project.yaml >/dev/null && fixed "applied apps/project.yaml"
    fi

    echo "- sealed-secrets controller"
    if ! kc -n argocd get app sealed-secrets >/dev/null 2>&1; then
      bad "Application sealed-secrets not created"
      fixing && kc apply -f apps/sealed-secrets.yaml >/dev/null && fixed "applied apps/sealed-secrets.yaml"
    fi
    if kc -n argocd get app sealed-secrets >/dev/null 2>&1; then
      local st; st="$(app_state sealed-secrets)"
      if [ "$st" = "Synced/Healthy" ]; then ok "app $st"
      else
        bad "app state: ${st:-unknown}"; app_msgs sealed-secrets | sed 's/^/          /'
        if fixing; then
          kc -n argocd annotate app sealed-secrets argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1
          echo "          refreshing, waiting up to 3 min..."
          wait_for 180 bash -c "[ \"\$(kubectl --context $CTX -n argocd get app sealed-secrets -o jsonpath='{.status.sync.status}/{.status.health.status}')\" = Synced/Healthy ]" \
            && fixed "app Synced/Healthy" || app_msgs sealed-secrets | sed 's/^/          still: /'
        fi
      fi
      if kc -n sealed-secrets get deploy sealed-secrets >/dev/null 2>&1 \
         && [ "$(kc -n sealed-secrets get deploy sealed-secrets -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ]; then
        ok "controller deployment ready"; SS_READY=1
      else
        bad "controller deployment not ready"
      fi
    fi
  else
    warn "skipping cluster checks (cluster unreachable)"
  fi

  echo "- secrets.env"
  if [ ! -f secrets.env ]; then
    bad "secrets.env missing"
    fixing && cp secrets.env.example secrets.env && fixed "created from secrets.env.example"
  fi
  if [ -f secrets.env ]; then
    local missing=() k len
    for k in $REQ_KEYS; do [ -n "$(env_get "$k")" ] || missing+=("$k"); done
    if [ ${#missing[@]} -eq 0 ]; then ok "all required keys set"
    else
      bad "empty: ${missing[*]}"
      if fixing && confirm "generate random URL-safe values for these (fine for a fresh cluster)?"; then
        for k in "${missing[@]}"; do
          len=24; [ "$k" = COLLECTOR_FALCO_TOKEN ] && len=32
          env_set "$k" "$(openssl rand -hex "$len")"
        done
        fixed "generated ${#missing[@]} value(s); not printed, they live in secrets.env (gitignored)"
      fi
    fi
  fi

  echo "- collector-secrets/ (SSH key + inventory)"
  if [ -f "$KEY" ]; then ok "$KEY present"
  else
    bad "$KEY missing"
    if fixing && confirm "generate a dedicated ed25519 key? (it must then be authorised on the nodes: stage 'lab')"; then
      mkdir -p collector-secrets && chmod 700 collector-secrets
      ssh-keygen -q -t ed25519 -N "" -C cortex-collector -f "$KEY" && fixed "key created"
    fi
  fi
  if [ -f "$INV" ]; then
    local n; n="$(grep -c 'ansible_host=' "$INV")"
    [ "$n" -ge 1 ] && ok "$INV has $n ansible_host entries" || bad "$INV has no ansible_host= entries"
    local ip; for ip in $NODES; do grep -q "ansible_host=$ip\b" "$INV" || warn "node $ip not in $INV (stale inventory?)"; done
  else
    bad "$INV missing"
    if fixing && [ -f "$CORTEX_REPO/infra/ansible/inventory/hosts.ini" ]; then
      mkdir -p collector-secrets && cp "$CORTEX_REPO/infra/ansible/inventory/hosts.ini" "$INV" && fixed "copied from $CORTEX_REPO"
    else
      manual "copy your inventory to $INV (from \$CORTEX_REPO/infra/ansible/inventory/hosts.ini)"
    fi
  fi

  echo "- sealed files (overlays/$OVERLAY)"
  local f miss=0
  for f in sealed-cortex-secrets.yaml sealed-collector-ssh.yaml; do
    if [ -s "overlays/$OVERLAY/$f" ]; then ok "$f present"; else bad "$f missing"; miss=1; fi
  done
  if [ "$miss" = 1 ] || [ "${RESEAL:-0}" = 1 ]; then
    if fixing && [ "$SS_READY" = 1 ] && [ -f secrets.env ] && [ -f "$KEY" ] && [ -f "$INV" ]; then
      with_ctx "$CTX" env OVERLAY="$OVERLAY" ./scripts/seal-secrets.sh && fixed "sealed" || bad "seal-secrets.sh failed (its message is above)"
    elif fixing; then
      warn "cannot seal yet: needs controller ready + secrets.env + key + inventory (see above)"
    fi
  fi

  echo "- kustomization lists the sealed files"
  local kz="overlays/$OVERLAY/kustomization.yaml"
  for f in sealed-cortex-secrets.yaml sealed-collector-ssh.yaml; do
    if grep -qE "^  - $f\$" "$kz"; then
      [ -s "overlays/$OVERLAY/$f" ] && ok "$f enabled" || bad "$f is listed but the file does not exist (this is the CI failure)"
    elif [ -s "overlays/$OVERLAY/$f" ]; then
      bad "$f exists but is not enabled in $kz"
      fixing && enable_resource "$kz" "$f" && fixed "enabled $f"
    else
      warn "$f not enabled (file missing too)"
    fi
  done

  echo "- gitleaks allowlist"
  if grep -qF '[[allowlists]]' .gitleaks.toml 2>/dev/null; then ok ".gitleaks.toml has the SealedSecret allowlist"
  else
    bad ".gitleaks.toml lacks the allowlist (CI flags ciphertext as generic-api-key)"
    if fixing; then
      cat > .gitleaks.toml <<'EOF'
title = "cortex-gitops"

# This repo holds SealedSecrets (encrypted) and nothing else sensitive.
# Keep the default ruleset. The single allowlist below exists because gitleaks'
# generic-api-key rule flags SealedSecret ciphertext (key name + high entropy).
[extend]
useDefault = true

[[allowlists]]
description = "SealedSecret ciphertext: encrypted to the cluster public key, safe to commit"
condition = "AND"   # path AND value shape must both match
paths = ['''overlays/[^/]+/sealed-[^/]+\.yaml$''']
regexes = ['''^Ag[A-Za-z0-9+/=]{200,}$''']
EOF
      fixed "wrote .gitleaks.toml"
    fi
  fi
  if [ -s "overlays/$OVERLAY/sealed-cortex-secrets.yaml" ]; then
    local short
    short="$(awk '/encryptedData/{f=1;next} f&&/^    [A-Za-z_]+:/{ if (length($2)<200 || $2 !~ /^Ag/) print $1 } f&&!/^    /{f=0}' "overlays/$OVERLAY/sealed-cortex-secrets.yaml")"
    [ -z "$short" ] && ok "all encryptedData values look like ciphertext" || bad "values that do NOT look like ciphertext: $short"
  fi

  echo "- manifests validate"
  if have kustomize && have kubeconform; then
    if ./scripts/validate.sh >/tmp/rollout-validate.log 2>&1; then ok "validate.sh passed"
    else bad "validate.sh failed (tail of /tmp/rollout-validate.log):"; tail -5 /tmp/rollout-validate.log | cut -c1-240 | sed 's/^/          /'; fi
  else
    warn "skipped (install kustomize + kubeconform)"
  fi

  echo "- git"
  if git grep -qI "BEGIN OPENSSH PRIVATE KEY" -- . ':!scripts' 2>/dev/null \
     || [ -n "$(git log --all -S'BEGIN OPENSSH PRIVATE KEY' --oneline -- . ':!scripts' 2>/dev/null)" ]; then
    bad "a private key is (or was) in git history: rotate the key and rewrite history before pushing"
  else
    ok "no private key in git"
  fi
  local branch dirty=() p
  branch="$(git rev-parse --abbrev-ref HEAD)"
  for p in "overlays/$OVERLAY/sealed-cortex-secrets.yaml" "overlays/$OVERLAY/sealed-collector-ssh.yaml" "overlays/$OVERLAY/kustomization.yaml" .gitleaks.toml; do
    [ -e "$p" ] || continue
    if ! git ls-files --error-unmatch "$p" >/dev/null 2>&1 || ! git diff --quiet HEAD -- "$p"; then dirty+=("$p"); fi
  done
  if [ ${#dirty[@]} -eq 0 ]; then ok "sealed files, kustomization and gitleaks config are committed"
  else
    bad "not committed: ${dirty[*]}"
    if fixing && [ "$branch" != main ]; then
      if confirm "commit them on '$branch'?"; then
        git add -- "${dirty[@]}" && git commit -q -m "feat($OVERLAY): sealed secrets + gitleaks ciphertext allowlist" && fixed "committed"
      fi
    elif fixing; then warn "on main: switch to a feature branch first (git checkout -b feat/...)"; fi
  fi
  if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    local ahead; ahead="$(git rev-list --count '@{u}..HEAD')"
    if [ "$ahead" = 0 ]; then ok "branch is pushed"
    else
      bad "$ahead commit(s) not pushed"
      fixing && [ "$branch" != main ] && confirm "git push?" && git push -q && fixed "pushed"
    fi
  else
    bad "branch '$branch' has no upstream"
    fixing && [ "$branch" != main ] && confirm "git push -u origin $branch?" && git push -q -u origin HEAD && fixed "pushed"
  fi

  echo "- merged to main (Argo reads main)"
  MERGED=0
  git fetch -q origin main 2>/dev/null
  if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then ok "HEAD is contained in origin/main"; MERGED=1
  else
    bad "not merged into main yet"
    if have gh && fixing && [ "$branch" != main ] && [ -z "$(gh pr list --head "$branch" --json number -q '.[].number' 2>/dev/null)" ]; then
      confirm "open a PR with gh?" && gh pr create --fill >/dev/null && fixed "PR opened"
    fi
    manual "wait for 'Secret scan (gitleaks)' and 'Validate manifests' to go green on the PR, then merge it (this script never merges)"
  fi

  [ "$CLUSTER_OK" = 1 ] || return 0

  echo "- hand-off to Argo (the last manual kubectl apply)"
  if kc -n argocd get app cortex-k3d >/dev/null 2>&1; then
    warn "app cortex-k3d also exists: use cortex-k3d OR cortex-k3d-sealed, never both"
  fi
  if kc -n argocd get app cortex-k3d-sealed >/dev/null 2>&1; then ok "app cortex-k3d-sealed exists"
  elif [ "$MERGED" = 1 ]; then
    bad "app cortex-k3d-sealed not applied"
    if fixing && confirm "load images and apply apps/cortex-k3d-sealed.yaml?"; then
      if [ -d "$CORTEX_REPO" ]; then CORTEX_REPO="$CORTEX_REPO" ./scripts/k3d-load-images.sh || warn "k3d-load-images.sh failed"
      else warn "CORTEX_REPO=$CORTEX_REPO not found: skipping local image build"; fi
      kc apply -f apps/cortex-k3d-sealed.yaml >/dev/null && fixed "applied"
    fi
  else
    warn "not applied, and not merged yet (do this after the merge)"
  fi

  echo "- verify"
  if kc -n argocd get app cortex-k3d-sealed >/dev/null 2>&1; then
    local s; s="$(app_state cortex-k3d-sealed)"
    [ "$s" = "Synced/Healthy" ] && ok "cortex-k3d-sealed $s" || { bad "cortex-k3d-sealed: ${s:-unknown}"; app_msgs cortex-k3d-sealed | sed 's/^/          /'; }
    local nr; nr="$(kc -n cortex get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); if (a[1]!=a[2] || $3!="Running") c++} END{print c+0}')"
    local np; np="$(kc -n cortex get pods --no-headers 2>/dev/null | wc -l)"
    if [ "$np" -gt 0 ] && [ "$nr" = 0 ]; then ok "$np pods Running and Ready"
    else bad "$nr of $np pods not ready"; kc -n cortex get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); if (a[1]!=a[2] || $3!="Running") print "          " $1, $2, $3}'; fi
    for f in cortex-secrets collector-ssh; do
      kc -n cortex get secret "$f" >/dev/null 2>&1 && ok "secret $f decrypted" || bad "secret $f missing (sealed against another cluster? re-seal)"
    done
    local code; code="$(curl -s -o /dev/null -w '%{http_code}' -m 6 http://cortex.localhost:8080/ 2>/dev/null)"
    case "$code" in 2*|3*) ok "web answers on cortex.localhost:8080 ($code)" ;; *) bad "web returned '$code'" ;; esac
    kc -n cortex exec deploy/api -- python -c "import urllib.request;urllib.request.urlopen('http://localhost:8000/health/db',timeout=5).read()" >/dev/null 2>&1 \
      && ok "api /health/db OK" || bad "api /health/db failed"
    local tok res; tok="$(env_get COLLECTOR_FALCO_TOKEN 2>/dev/null)"
    res="$(kc -n cortex exec -i deploy/api -- python - <<EOF 2>/dev/null
import urllib.request, urllib.error, json
def call(url, data=None):
    try:
        req = urllib.request.Request(url, data=data, headers={"content-type": "application/json"})
        return urllib.request.urlopen(req, timeout=5).status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:
        return "err"
print("health", call("http://collector:9110/health"))
body = json.dumps({"rule":"rollout-check","priority":"Warning","output":"hello","hostname":"controller","time":"2026-01-01T00:00:00Z"}).encode()
print("falco_ok", call("http://collector:9110/falco?token=${tok}", body))
print("falco_bad", call("http://collector:9110/falco?token=wrong", body))
EOF
)"
    echo "$res" | grep -q '^falco_ok 200' && ok "Falco intake accepts the real token" || bad "Falco intake with real token: $(echo "$res" | grep falco_ok)"
    echo "$res" | grep -q '^falco_bad 401' && ok "Falco intake rejects a wrong token (401)" || warn "wrong-token result: $(echo "$res" | grep falco_bad)"
    echo "$res" | grep -q '^health 200' && ok "collector /health 200" \
      || warn "collector /health: $(echo "$res" | grep '^health') (503 = no route to the lab or first refresh not done: expected in plain k3d)"
  fi

  echo "- sealing-key backup (outside git)"
  local bk="$HOME/sealed-key-backup.yaml"
  if [ -s "$bk" ]; then ok "$bk exists"
  elif [ "$SS_READY" = 1 ]; then
    warn "no backup of the sealed-secrets private key"
    if fixing && confirm "write it to $bk (chmod 600; it can decrypt every SealedSecret, keep it OUT of git)?"; then
      ( umask 077; kc -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > "$bk" ) && fixed "saved $bk"
    fi
  fi
}

# ----------------------------------------------------------------------------------------
stage_lab() {
  section "B. Lab side of the collector (nodes: $NODES)"

  echo "- SSH from this machine with the collector key"
  if [ ! -f "$KEY" ]; then warn "no $KEY yet (run stage k3d with --fix first)"
  else
    local ip
    for ip in $NODES; do
      if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new "root@$ip" 'hostname' >/tmp/rollout-ssh.out 2>/tmp/rollout-ssh.err; then
        ok "root@$ip ($(cat /tmp/rollout-ssh.out))"
      else
        bad "root@$ip: $(tail -1 /tmp/rollout-ssh.err | cut -c1-120)"
        if fixing && confirm "authorise the collector key on $ip (asks for that node's password)?"; then
          ssh-keygen -y -f "$KEY" > /tmp/rollout-collector.pub \
            && ssh-copy-id -i /tmp/rollout-collector.pub "root@$ip" \
            && ssh -i "$KEY" -o BatchMode=yes "root@$ip" 'hostname' >/dev/null 2>&1 && fixed "key authorised on $ip"
          rm -f /tmp/rollout-collector.pub
        fi
      fi
    done
  fi

  echo "- collector config"
  if grep -qE '^COLLECTOR_TRIVY_HOSTS=.+' base/config/collector.env; then ok "COLLECTOR_TRIVY_HOSTS is set"
  else
    bad "COLLECTOR_TRIVY_HOSTS is empty (Trivy would run on every node, including the compute node)"
    fixing && sed -i "s|^COLLECTOR_TRIVY_HOSTS=.*|COLLECTOR_TRIVY_HOSTS=$TRIVY_HOSTS|" base/config/collector.env && fixed "set COLLECTOR_TRIVY_HOSTS=$TRIVY_HOSTS (commit it via a PR)"
  fi
  if grep -qE '^[[:space:]]*- CORTEX_KEYSTONE_EXPECTED_CIDRS=' overlays/azure/kustomization.yaml; then ok "CORTEX_KEYSTONE_EXPECTED_CIDRS enabled in the azure overlay"
  else
    bad "CORTEX_KEYSTONE_EXPECTED_CIDRS still commented in overlays/azure/kustomization.yaml"
    fixing && sed -i -E 's|^([[:space:]]*)# - (CORTEX_KEYSTONE_EXPECTED_CIDRS=)|\1- \2|' overlays/azure/kustomization.yaml && fixed "enabled (value 10.0.1.0/24; commit via a PR)"
  fi

  echo "- network path (cannot be checked from here)"
  manual "AKS pod -> nodes :22 over VPN/peering: from any AKS pod run  nc -vz 10.0.1.4 22  (then .6 and .7)"
  manual "nodes -> collector :9110: the internal load balancer IP must be reachable from the nodes (curl it from a node)"
}

# ----------------------------------------------------------------------------------------
stage_azure() {
  section "C. Azure / AKS overlay"
  local kz=overlays/azure/kustomization.yaml f

  echo "- image digests"
  local nd zero
  nd="$(grep -cE '^[[:space:]]*digest: sha256:[0-9a-f]{64}$' "$kz")"
  zero="$(grep -cE 'sha256:0{64}' "$kz")"
  [ "$nd" -ge 3 ] && [ "$zero" = 0 ] && ok "3 real digests (api, web, collector)" || bad "digests missing or placeholder ($nd found, $zero all-zero): merge the Cortex handoff PR"
  local unpinned
  unpinned="$(grep -rhE '^[[:space:]]*image:' base | grep -vE '@sha256:|ghcr.io/lakhal-farah' | sed 's/^[[:space:]]*//' | sort -u)"
  [ -z "$unpinned" ] && ok "third-party images pinned" || warn "unpinned third-party images (run ./scripts/pin-digests.sh, then PR): $(echo "$unpinned" | paste -sd' ' -)"

  echo "- AKS context"
  if [ -z "$AKS_CTX" ]; then
    manual "set AKS_CTX=<context> (az aks get-credentials -g <rg> -n <cluster>; kubectl config get-contexts) and re-run: AKS_CTX=... $0 --fix azure"
  elif ! kubectl --context "$AKS_CTX" get --raw /readyz >/dev/null 2>&1; then
    bad "AKS context '$AKS_CTX' unreachable"
  else
    ok "AKS context '$AKS_CTX' reachable"
    local akc="kubectl --context $AKS_CTX"
    if $akc -n argocd get deploy argocd-server >/dev/null 2>&1; then ok "Argo CD present on AKS"
    else bad "Argo CD not installed on AKS"; manual "install Argo CD on AKS: kubectl config use-context $AKS_CTX && ./scripts/argocd-install.sh"; fi
    $akc -n argocd get appproject cortex >/dev/null 2>&1 && ok "AppProject cortex on AKS" || {
      bad "AppProject cortex missing on AKS"
      fixing && $akc apply -f apps/project.yaml >/dev/null && fixed "applied project"; }
    if $akc -n sealed-secrets get deploy sealed-secrets >/dev/null 2>&1; then ok "sealed-secrets controller on AKS"
    else
      bad "sealed-secrets controller missing on AKS"
      fixing && $akc apply -f apps/sealed-secrets.yaml >/dev/null && fixed "applied apps/sealed-secrets.yaml (wait for it to sync, then re-run)"
    fi
    if [ ! -s overlays/azure/sealed-cortex-secrets.yaml ] || [ ! -s overlays/azure/sealed-collector-ssh.yaml ] || [ "${RESEAL:-0}" = 1 ]; then
      bad "azure sealed files missing (k3d-sealed files do NOT decrypt on AKS)"
      if fixing && $akc -n sealed-secrets get deploy sealed-secrets >/dev/null 2>&1 \
         && confirm "seal for AKS now? Uses the REAL key in $KEY and the real $INV"; then
        with_ctx "$AKS_CTX" env OVERLAY=azure ./scripts/seal-secrets.sh && fixed "sealed for AKS" || bad "seal failed"
      fi
    else ok "azure sealed files present"; fi
  fi

  echo "- overlay wiring"
  for f in sealed-cortex-secrets.yaml sealed-collector-ssh.yaml; do
    if grep -qE "^  - $f\$" "$kz"; then ok "$f enabled"
    elif [ -s "overlays/azure/$f" ]; then bad "$f exists but is commented out"; fixing && enable_resource "$kz" "$f" && fixed "enabled $f"
    else warn "$f not enabled yet (seal first)"; fi
  done
  if [ ! -f overlays/azure/falco-intake.yaml ]; then
    bad "falco-intake.yaml not created"
    if fixing; then
      cp overlays/azure/falco-intake.yaml.example overlays/azure/falco-intake.yaml
      sed -i '/10\.0\.2\.0\/24/d' overlays/azure/falco-intake.yaml
      fixed "created falco-intake.yaml (source range 10.0.1.0/24 only; the old 10.0.2.0/24 line removed)"
    fi
  else
    grep -q '10\.0\.2\.0/24' overlays/azure/falco-intake.yaml && { bad "falco-intake.yaml still allows the old 10.0.2.0/24"; fixing && sed -i '/10\.0\.2\.0\/24/d' overlays/azure/falco-intake.yaml && fixed "removed"; } || ok "falco-intake.yaml source ranges OK"
  fi
  if [ -f overlays/azure/falco-intake.yaml ]; then
    grep -qE '^  - falco-intake.yaml$' "$kz" && ok "falco-intake enabled" || { bad "falco-intake.yaml not enabled"; fixing && enable_resource "$kz" falco-intake.yaml && fixed "enabled"; }
  fi
  if [ -f overlays/azure/ingress.yaml ]; then
    grep -qE '^  - ingress.yaml$' "$kz" && ok "ingress enabled" || { bad "ingress.yaml exists but is not enabled"; fixing && enable_resource "$kz" ingress.yaml && fixed "enabled"; }
  else
    bad "ingress.yaml missing"
    manual "cp overlays/azure/ingress.yaml.example overlays/azure/ingress.yaml and set ingress class, host, TLS (your choices), then enable it"
  fi
  grep -q 'cortex.example.com' "$kz" && { bad "CORTEX_PUBLIC_URL is still cortex.example.com"; manual "set the real CORTEX_PUBLIC_URL in $kz"; } || ok "CORTEX_PUBLIC_URL customised"
  grep -qE '^[[:space:]]*- (PROMETHEUS_URL|LOKI_URL)=' "$kz" && ok "Prometheus/Loki URLs set" || manual "uncomment and set PROMETHEUS_URL, PROMETHEUS_RANGE_URL, PROMETHEUS_BASE_URL, LOKI_URL (and QDRANT_URL) in $kz"

  echo "- steps only you can do"
  manual "run the Falco playbook with the collector-falco LB IP:  ansible-playbook playbook-falco.yml -e falco_collector_host=<IP> -e falco_collector_token=<token>"
  manual "keep the compose collector STOPPED once the cluster one is live"
  manual "then: kubectl --context <aks> apply -f apps/cortex-azure.yaml and sync; check the Security cards in the UI"
}

# ----------------------------------------------------------------------------------------
for s in "${STAGES[@]}"; do "stage_$s"; done

section "Summary"
echo "  ok: $PASS   warnings: $WARN   failures: $FAIL   manual steps: ${#TODO[@]}"
if [ ${#TODO[@]} -gt 0 ]; then
  echo; echo "Manual steps (the script cannot do these):"
  printf '  - %s\n' "${TODO[@]}"
fi
[ "$FIX" = 1 ] || { [ "$FAIL" -gt 0 ] && echo && echo "Run again with --fix to let the script repair what it can."; }
[ "$FAIL" -eq 0 ]