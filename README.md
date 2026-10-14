# cortex-gitops

Desired state of the [Cortex](https://github.com/LAKHAL-Farah/Cortex) platform on Kubernetes.
The Cortex CI builds, scans, signs and attests the images; **this repo decides what runs**.
CI never deploys: it opens a PR here that bumps image digests.

```
base/                 environment-neutral manifests (derived from infra/docker-compose.yml)
overlays/k3d/         local rehearsal: local images, DEV secrets, mailpit, Traefik ingress
overlays/k3d-sealed/  same, but secrets come from a SealedSecret (no plaintext in git)
overlays/azure/       Azure k3s (3 VMs): digest-pinned images (bumped by CI), SealedSecret, Traefik ingress; collector stays in the lab
apps/                 Argo CD AppProject + Applications (k3d, azure, sealed-secrets, cert-manager, issuers)
platform/             cluster-scoped platform config (Let's Encrypt ClusterIssuers)
scripts/              validate / k3d helpers / secret sealing
```

## What runs

| Workload | Kind | Notes |
|---|---|---|
| `api` | Deployment (1 replica, `Recreate`) | probes `/health` (start/live) and `/health/db` (ready); singleton because schedulers run in-process |
| `web` | Deployment | `CORTEX_API_URL=http://api:8000`; probes `/login` |
| `postgres` | StatefulSet + PVC | `postgres:16`, runs as uid 999 |
| `neo4j` | StatefulSet + PVC | `neo4j:5-community`, runs as uid 7474 |
| `collector` | Deployment (1 replica, `Recreate`) + PVC | security collector: SSH to the nodes (packages, ports, Trivy, Keystone log) and Falco intake on `:9110`; needs `collector-ssh` Secret and a route to the nodes, see `GUIDE-collector.md` |

All pods: `runAsNonRoot`, `seccompProfile: RuntimeDefault`, all capabilities dropped, no
privilege escalation, no service-account token, no service-link env vars, resource requests and
limits. `readOnlyRootFilesystem` is on everywhere (writable paths are emptyDirs/PVCs) **except
neo4j** (see the comment in `base/neo4j.yaml`). The namespace enforces the Pod Security
`restricted` profile. `CORTEX_REMEDIATION_EXECUTION=off`.

Dropped from the compose stack (sandbox-only): the file_sd host mount, Ansible dir, SSH keys,
`clouds.yaml`, bind-mounted source, and the host port bindings.

## Validate

```bash
./scripts/validate.sh        # needs kustomize + kubeconform
```

## Local rehearsal on k3d

Needs Docker, `k3d`, `kubectl`, and a checkout of the Cortex repo next to this one.

```bash
./scripts/k3d-up.sh                      # cluster + :8080 -> Traefik
CORTEX_REPO=../Cortex ./scripts/k3d-load-images.sh   # build + import cortex-{api,web}:local
./scripts/k3d-apply.sh                   # kubectl apply -k overlays/k3d, waits for rollout
```

Open <http://cortex.localhost:8080> (`admin` / `dev-admin-Passw0rd`; the app forces a change).
Mail sink: <http://mail.cortex.localhost:8080>. If `*.localhost` does not resolve:
`kubectl -n cortex port-forward svc/web 3000:3000`.

### Same thing through Argo CD (the real GitOps loop, sealed secrets)

```bash
./scripts/argocd-install.sh                       # pinned + checksum-verified Argo CD, AppProject
kubectl apply -f apps/sealed-secrets.yaml         # controller (chart pinned), installed by Argo
kubectl -n sealed-secrets rollout status deploy/sealed-secrets
cp secrets.env.example secrets.env                # fill in (URL-safe passwords)
OVERLAY=k3d-sealed ./scripts/seal-secrets.sh      # -> overlays/k3d-sealed/sealed-cortex-secrets.yaml
# uncomment `- sealed-cortex-secrets.yaml` in overlays/k3d-sealed/kustomization.yaml,
# commit on a branch, open a PR, merge it (Argo reads main)
kubectl apply -f apps/cortex-k3d-sealed.yaml      # the LAST manual kubectl apply
```

Use `cortex-k3d-sealed` **or** `cortex-k3d` (DEV secrets), never both. The sealing key lives in
the cluster: after `k3d-down.sh` you must re-seal (or back up/restore the key with
`kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml`,
stored OUTSIDE git). Tear down: `./scripts/k3d-down.sh`.

Pull check (Step 5): `./scripts/k3d-pull-test.sh sha256:<digest> [api|web]`.
Pin third-party images: `./scripts/pin-digests.sh` (needs `crane` + `yq`).

## Image digests

`overlays/azure/kustomization.yaml` `images:` is rewritten by the Cortex CI `gitops-handoff`
job (`yq` sets `.digest` on the entry whose `.name` matches). The all-zero digests are
placeholders; the PR check warns while they remain. Names must stay exactly
`ghcr.io/lakhal-farah/cortex-{api,web,collector}`.

## Secrets

Only **SealedSecrets** are committed. `cortex-secrets` must contain
`CORTEX_DB_PASSWORD`, `CORTEX_NEO4J_PASSWORD`, `CORTEX_API_KEY`, `CORTEX_JWT_SECRET`,
`CORTEX_ADMIN_PASSWORD`, `COLLECTOR_FALCO_TOKEN` (required) and `QDRANT_URL`, `QDRANT_API_KEY`, `NVIDIA_API_KEY`, `TAVILY_API_KEY`,
`SMTP_USERNAME`, `SMTP_PASSWORD` (optional).

```bash
cp secrets.env.example secrets.env   # gitignored; fill it in (URL-safe passwords)
./scripts/seal-secrets.sh            # -> overlays/azure/sealed-cortex-secrets.yaml
```

A second Secret, `collector-ssh` (key `id_ed25519` + `hosts.ini` from the gitignored `collector-secrets/`), is sealed by the same script. Then uncomment both sealed files in `overlays/azure/kustomization.yaml`. CI fails if the azure overlay ever
renders a plaintext `Secret`. The k3d overlay contains fake DEV credentials on purpose.

## Known gaps (compared with the compose stack)

- **Knowledge ingest**: `docs/knowledge` is not in the API image, so `POST /knowledge/ingest` has nothing to read.
- **Node onboarding via Ansible / OpenStack sync**: disabled (no inventory, no `clouds.yaml`). OpenStack-backed pages will show errors until a Secret-mounted `clouds.yaml` is added.
- **Prometheus / Loki** are not deployed here; set their URLs in the overlay.
- No NetworkPolicies yet.
