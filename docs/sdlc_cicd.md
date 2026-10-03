# EQ Tech – SDLC and CI/CD Process

## 1. Overview

The EQ Tech platform uses **branch-based development** with three long-lived branches mapped
one-to-one to deployment environments. Promotion between environments is done exclusively
via Pull Request — never by direct push.

```
feature/* ──► develop ──PR──► uat ──PR──► main
                │               │           │
                ▼               ▼           ▼
              dev env        UAT env     prod env
           (auto-deploy)   (auto-deploy) (auto-deploy)
```

**Three CI/CD pipelines** live in `.github/workflows/`. Each pipeline contains three
independent jobs gated by `if: github.ref == 'refs/heads/<branch>'`. Only the job
matching the branch that was pushed runs — the other two are skipped automatically.

A fourth pipeline, `lint-test.yml`, runs on every PR and every push to any of the three
long-lived branches, blocking merge if linting or tests fail.

**DAG files** (`data/airflow/dags/**`) are synced directly by the `git-sync` sidecar in
each Airflow scheduler pod:

| Environment | git-sync branch |
|---|---|
| `dev-airflow` | `develop` |
| `uat-airflow` | `uat` |
| `prod-airflow` | `main` |

A DAG change merged to `develop` appears in dev within 30 seconds with no pipeline run.
It only reaches UAT Airflow after `develop` is promoted to `uat` via PR, and prod Airflow
after `uat` is promoted to `main`.

---

## 2. Branching Strategy

### 2.1 Long-lived branches

| Branch | Environment | Deploys on | Requires PR to merge |
|---|---|---|---|
| `develop` | dev | push (auto) | Yes — lint-test must pass |
| `uat` | UAT | push (auto) | Yes — lint-test must pass, ≥ 1 reviewer |
| `main` | prod | push (auto) | Yes — lint-test must pass, ≥ 2 reviewers |

### 2.2 Short-lived branches

| Pattern | Purpose | Branch from | Merges into |
|---|---|---|---|
| `feature/<ticket>-description` | New features, DAGs, lib changes | `develop` | `develop` via PR |
| `fix/<ticket>-description` | Bug fixes targeting dev/UAT | `develop` | `develop` via PR |
| `hotfix/<ticket>-description` | Production incident fix | `main` | `main` via PR, then back-merge `main → uat → develop` |
| `release/*` | Optional stabilisation buffer | `uat` | `main` via PR |

### 2.3 Rules

- **Never push directly** to `develop`, `uat`, or `main` — branch protection blocks it.
- Feature branches are short-lived (target < 2 days). Incomplete features use feature flags.
- `hotfix/*` branches are the only exception to the `develop`-first rule.

---

## 3. Developer Daily Workflow

```
1. Pull latest develop
   git checkout develop && git pull

2. Create a feature branch
   git checkout -b feature/EQ-42-add-risk-etl-dag

3. Develop on the central dev server (SSH in → venv auto-activated)
   ssh alice@<DEVBOX_IP>
   cd ~/eq_tech

4. Test locally before pushing
   # Run Airflow DAG unit test
   airflow dags test daily_etl 2024-01-01

   # Run API tests
   pytest tests/

   # Lint
   ruff check apps/ data/ lib/

5. Push branch and open a Pull Request targeting develop
   git push -u origin feature/EQ-42-add-risk-etl-dag
   # Open PR at https://github.com/ColumbiaDataScienceCorporation/eq_tech
   # Set base branch to: develop

6. PR checks run automatically (lint-test.yml)
   Code review by at least one team member

7. Merge to develop
   # GitHub Actions deploys the change to dev-airflow / dev-apps automatically

8. Verify dev, then promote to UAT
   # Open a PR: develop → uat
   # Requires ≥ 1 reviewer approval + lint-test passing

9. Verify UAT, then promote to prod
   # Open a PR: uat → main
   # Requires ≥ 2 reviewer approvals + lint-test passing
```

---

## 4. CI/CD Pipeline Overview

### 4.1 What triggers what

Each of the three deployment pipelines listens on all three long-lived branches but uses
an `if:` guard so only the matching job runs:

| Workflow | Trigger paths | Branch pushed | Job that runs |
|---|---|---|---|
| `infra-ci.yml` | `infra/terraform/**` | `develop` | `deploy-dev` only |
| `infra-ci.yml` | `infra/terraform/**` | `uat` | `deploy-uat` only |
| `infra-ci.yml` | `infra/terraform/**` | `main` | `deploy-prod` only |
| `airflow-helm-deploy.yml` | `infra/helm/airflow-values**`, `data/airflow/docker/**` | `develop` | `deploy-dev` only |
| `airflow-helm-deploy.yml` | same | `uat` | `deploy-uat` only |
| `airflow-helm-deploy.yml` | same | `main` | `deploy-prod` only |
| `apps-ci.yml` | `apps/**`, `k8s/**`, `lib/**` | `develop` | `build` + `deploy-dev` |
| `apps-ci.yml` | same | `uat` | `build` + `deploy-uat` |
| `apps-ci.yml` | same | `main` | `build` + `deploy-prod` |
| `lint-test.yml` | any | PR or push to `develop`/`uat`/`main` | `lint-test` (always) |

**DAG files only** (`data/airflow/dags/**`): no pipeline runs at all. `git-sync` handles
delivery within 30 seconds of the branch receiving the commit.

### 4.2 `infra-ci.yml` — Terraform Infrastructure

```
push to develop ──► [deploy-dev]   terraform workspace dev
push to uat     ──► [deploy-uat]   terraform workspace uat
push to main    ──► [deploy-prod]  terraform workspace prod
```

Each job: `terraform init` → `terraform workspace select` → `terraform apply -auto-approve`.

### 4.3 `airflow-helm-deploy.yml` — Airflow Helm Upgrades

```
push to develop ──► [deploy-dev]   helm upgrade airflow-dev  -n dev-airflow
push to uat     ──► [deploy-uat]   helm upgrade airflow-uat  -n uat-airflow
push to main    ──► [deploy-prod]  helm upgrade airflow-prod -n prod-airflow
```

Each job uses `airflow-values.yaml` (base) layered with the environment overlay
(`airflow-values/dev.yaml`, `airflow-values/uat.yaml`, `airflow-values/prod.yaml`).
The environment overlay sets `dags.gitSync.branch` to the matching branch.

### 4.4 `apps-ci.yml` — Application Build and Deploy

```
push to develop:
  [build]  → docker build + push :<sha> and :develop to ACR
  [deploy-dev] (needs build) → kubectl apply + set image -n dev-apps

push to uat:
  [build]  → docker build + push :<sha> and :uat to ACR
  [deploy-uat] (needs build) → kubectl apply + set image -n uat-apps

push to main:
  [build]  → docker build + push :<sha>, :main, and :latest to ACR
  [deploy-prod] (needs build) → kubectl apply + set image -n prod-apps
```

`:latest` is only pushed from `main`, ensuring prod is always the source of truth for that tag.

### 4.5 `lint-test.yml` — Lint and Test Gate

Runs on every PR targeting `develop`, `uat`, or `main`, and on every direct push to those branches.

Steps: `ruff check .` → `pytest tests/ -q --tb=short`

This is a required status check on all three long-lived branches. A PR cannot be merged if it fails.

---

## 5. GitHub Environments

GitHub Environments enforce the OIDC token subject for Azure login and restrict which branch
can trigger a deployment.

| Environment | Deployment branch | Required reviewers | Wait timer |
|---|---|---|---|
| `dev` | `develop` only | None (auto-deploy) | None |
| `uat` | `uat` only | ≥ 1 | Optional (5 min) |
| `prod` | `main` only | ≥ 2 | 10 min recommended |

Navigate to `https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings/environments`
to manage reviewers and deployment branch restrictions.

---

## 6. Promotion Flow

### 6.1 Normal promotion (feature to prod)

```
Developer creates feature/EQ-42 from develop
         │
         ▼
PR: feature/EQ-42 → develop
  lint-test runs automatically
  Code review (no minimum for solo demo; ≥ 1 for team projects)
         │
         ▼ merge
develop → auto-deploys to dev environment
         │
         ▼ developer verifies dev
         │   https://dev.eq-tech.<LB_IP>.nip.io
         │   kubectl get pods -n dev-airflow
         │
         ▼ open PR: develop → uat
  lint-test runs; ≥ 1 reviewer approval required
         │
         ▼ merge
uat → auto-deploys to UAT environment
         │
         ▼ QA / stakeholders verify UAT
         │   https://uat.eq-tech.<LB_IP>.nip.io
         │
         ▼ open PR: uat → main
  lint-test runs; ≥ 2 reviewer approvals required
         │
         ▼ merge
main → auto-deploys to prod environment
```

### 6.2 Hotfix flow (production incident)

```
Incident detected in prod
         │
         ▼
git checkout main && git checkout -b hotfix/EQ-99-fix-scheduler-crash
         │
         ▼
PR: hotfix/EQ-99 → main   (emergency review, ≥ 1 reviewer)
         │
         ▼ merge → deploys to prod
         │
         ▼ back-merge to keep branches in sync:
PR: main → uat  (or cherry-pick)
PR: uat  → develop  (or cherry-pick)
```

### 6.3 Blocking a promotion

Close or decline the PR before merging. No pipeline runs. The previous environment remains
at its last deployed state until a new PR is opened and merged.

---

## 7. Quality Gates

### 7.1 Pre-merge checks (automated)

`lint-test.yml` is already configured and runs on every PR. It enforces:

| Check | Tool | Fails on |
|---|---|---|
| Import ordering, unused imports, style | `ruff check .` | Any ruff violation |
| Unit tests | `pytest tests/ -q --tb=short` | Any test failure |

`lint-test / lint-test` is a required status check on `develop`, `uat`, and `main`.
A PR cannot be merged until this check passes.

### 7.2 Post-deploy verification (dev)

After `develop` deploys, verify before opening the UAT promotion PR:

```bash
# API smoke test
curl -f https://dev.eq-tech.<LB_IP>.nip.io/api/healthz

# Airflow DAG parse check
kubectl exec -n dev-airflow \
  $(kubectl get pod -n dev-airflow -l component=scheduler -o name | head -1) \
  -- airflow dags list

# Pod health
kubectl get pods -n dev-airflow
kubectl get pods -n dev-apps
```

---

## 8. Rollback Procedures

### 8.1 Application rollback (fast — < 5 minutes)

Images are tagged with `${{ github.sha }}`. Roll back by pointing the deployment at
a previous SHA:

```bash
PREV_SHA=<previous_good_sha>
kubectl set image deployment/api \
  api=eqtechacr.azurecr.io/api:${PREV_SHA} \
  -n prod-apps
kubectl rollout status deployment/api -n prod-apps
```

Or use Kubernetes rollout history:
```bash
kubectl rollout undo deployment/api -n prod-apps
```

### 8.2 Airflow Helm rollback

```bash
helm history airflow-prod -n prod-airflow
helm rollback airflow-prod 0 -n prod-airflow  # 0 = previous revision
```

### 8.3 Terraform rollback

Use `git revert` on the affected branch — `infra-ci.yml` re-applies the reverted state
on the next push.

### 8.4 DAG rollback

```bash
# Revert on develop (for dev), uat (for UAT), or main (for prod)
git revert <commit_that_broke_dag>
git push origin develop   # or uat / main
# git-sync picks up the revert within 30 seconds
```

---

## 9. Feature Flags

Use Airflow Variables or Kubernetes environment variables to hide incomplete work that
has been merged to `develop` but is not ready to promote.

### Airflow Variable flag (for DAGs)

```python
from airflow.models import Variable

def new_risk_calculation(**kwargs):
    if Variable.get("ENABLE_NEW_RISK_CALC", default_var="false") == "true":
        # new experimental logic
        ...
    else:
        # existing stable logic
        ...
```

Set the flag per environment:
```bash
kubectl exec -n dev-airflow \
  $(kubectl get pod -n dev-airflow -l component=webserver -o name) \
  -- airflow variables set ENABLE_NEW_RISK_CALC true
```

### Pod environment variable flag (for apps)

Set `FEATURE_NEW_PORTFOLIO_VIEW=false` in the Kubernetes manifest. Override per environment
via the Helm overlay:

```yaml
# infra/helm/airflow-values/dev.yaml
env:
  - name: FEATURE_NEW_PORTFOLIO_VIEW
    value: "true"
```

---

## 10. Secrets Management

All secrets follow a single rule: **they exist in exactly one place and are never committed to the repository**.

| Secret | Where it lives | How it reaches the pod |
|---|---|---|
| PostgreSQL password | GitHub Actions Secret (`PG_ADMIN_PASSWORD`) | Passed as `-var` to Terraform; Terraform writes K8s secret `airflow-postgres-secret` |
| GitHub Fine-Grained PAT (git-sync) | GitHub Actions Secret (`GIT_SYNC_TOKEN`) | `kubectl create secret` in Phase 13 Step 7 |
| OAuth2 Proxy client secret | GitHub Actions Secret (`OAUTH2_CLIENT_SECRET`) | `kubectl create secret oauth2-proxy-secret` |
| Azure credentials (Terraform/kubectl) | OIDC federation — no stored credential; short-lived token per job | `azure/login@v2` action |
| Dev server managed identity | Azure RBAC (system-assigned) | `az login --identity` inside the quota auto-scale script |

Rotate secrets by:
1. Updating the value in GitHub Secrets (`Settings → Secrets → Actions`)
2. Re-running the K8s secret creation command for the affected namespace(s)
3. Restarting affected pods: `kubectl rollout restart deployment/<name> -n <ns>`
