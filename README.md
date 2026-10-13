# cortex-gitops

Desired state of the [Cortex](https://github.com/LAKHAL-Farah/Cortex) platform on Kubernetes.
The Cortex CI builds, scans, signs and attests the images; **this repo decides what runs**.
CI never deploys: it opens a PR here that bumps image digests.

```
base/                 environment-neutral manifests (derived from infra/docker-compose.yml)
overlays/k3d/         local rehearsal: local images, DEV secrets, mailpit, Traefik ingress
overlays/azure/       AKS: digest-pinned images (bumped by CI), SealedSecrets, your ingress
apps/                 Argo CD AppProject + Applications (k3d, azure, sealed-secrets controller)
scripts/              validate / k3d helpers / secret sealing
```

## What runs

| Workload | Kind | Notes |
|---|---|---|
| `api` | Deployment (1 replica, `Recreate`) | probes `/health` (start/live) and `/health/db` (ready); singleton because schedulers run in-process |
| `web` | Deployment | `CORTEX_API_URL=http://api:8000`; probes `/login` |
| `postgres` | StatefulSet + PVC | `postgres:16`, runs as uid 999 |
| `neo4j` | StatefulSet + PVC | `neo4j:5-community`, runs as uid 7474 |

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

### Same thing through Argo CD (the real GitOps loop)

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f apps/project.yaml -f apps/cortex-k3d.yaml
```

Argo pulls `overlays/k3d` from GitHub `main`, so push first. Tear down: `./scripts/k3d-down.sh`.

## Image digests

`overlays/azure/kustomization.yaml` `images:` is rewritten by the Cortex CI `gitops-handoff`
job (`yq` sets `.digest` on the entry whose `.name` matches). The all-zero digests are
placeholders; the PR check warns while they remain. Names must stay exactly
`ghcr.io/lakhal-farah/cortex-{api,web}`.

## Secrets

Only **SealedSecrets** are committed. `cortex-secrets` must contain
`CORTEX_DB_PASSWORD`, `CORTEX_NEO4J_PASSWORD`, `CORTEX_API_KEY`, `CORTEX_JWT_SECRET`,
`CORTEX_ADMIN_PASSWORD` (required) and `QDRANT_API_KEY`, `NVIDIA_API_KEY`, `TAVILY_API_KEY`,
`SMTP_USERNAME`, `SMTP_PASSWORD` (optional).

```bash
cp secrets.env.example secrets.env   # gitignored; fill it in (URL-safe passwords)
./scripts/seal-secrets.sh            # -> overlays/azure/sealed-cortex-secrets.yaml
```

Then uncomment it in `overlays/azure/kustomization.yaml`. CI fails if the azure overlay ever
renders a plaintext `Secret`. The k3d overlay contains fake DEV credentials on purpose.

## Known gaps (compared with the compose stack)

- **Knowledge ingest**: `docs/knowledge` is not in the API image, so `POST /knowledge/ingest` has nothing to read.
- **Node onboarding via Ansible / OpenStack sync**: disabled (no inventory, no `clouds.yaml`). OpenStack-backed pages will show errors until a Secret-mounted `clouds.yaml` is added.
- **Prometheus / Loki** are not deployed here; set their URLs in the overlay.
- No NetworkPolicies yet.
