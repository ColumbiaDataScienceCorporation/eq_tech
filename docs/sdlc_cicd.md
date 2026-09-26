# EQ Tech – SDLC and CI/CD Process

## 1. Overview

The EQ Tech platform uses **trunk-based development** with a single long-lived branch (`main`) and three deployment environments promoted sequentially: **dev → UAT → prod**. GitHub Actions implements the CI/CD pipelines; GitHub Environments enforce promotion gates with human approval for UAT and prod.

```
Developer workstation / central dev server
        │
        ├── Short-lived feature branch (< 2 days)
        │
        └── Pull Request → code review → merge to main
                                               │
                               ┌───────────────┼────────────────┐
                               ▼               ▼                ▼
                        infra-ci.yml   airflow-helm-      apps-ci.yml
                        (Terraform)    deploy.yml         (Docker + K8s)
                               │       (Helm)                   │
                        dev ─auto─►    dev ─auto─►       dev ─auto─►
                        uat ─gate─►    uat ─gate─►       uat ─gate─►
                        prod ─gate─►   prod ─gate─►      prod ─gate─►
```

**DAG files** (`data/airflow/dags/**`) are the exception: a push to `main` triggers **no pipeline at all**. The `git-sync` sidecar in every Airflow scheduler pod polls the repo every 30 seconds and loads updated DAGs automatically.

---

## 2. Branching Strategy (Trunk-Based Development)

| Rule | Detail |
|---|---|
| Single integration branch | `main` — always deployable |
| Feature branch lifetime | Max **2 working days**; ideally < 24 hours |
| Branch naming | `feat/<ticket>-short-description`, `fix/<ticket>-short-description`, `chore/<ticket>-description` |
| No long-lived branches | No `develop`, `release/*`, or `hotfix/*` branches |
| Incomplete features | Hidden behind **feature flags** (env var in pod spec or Airflow Variable) |
| Branch from | Always from `main` |
| Merge via | Pull Request (PR) — squash merge preferred to keep `main` history linear |

### Why Trunk-Based?

- The monorepo contains heterogeneous code types (DAGs, APIs, Helm charts, Terraform). Long-lived branches create drift across these layers simultaneously.
- `git-sync` pulls DAGs directly from `main` — a feature branch DAG is never deployed to any environment unless it merges.
- The sequential dev → UAT → prod promotion already provides environment isolation; separate branches would add overhead without protection.

---

## 3. Developer Daily Workflow

```
1. Pull latest main
   git checkout main && git pull

2. Create a short-lived feature branch
   git checkout -b feat/EQ-42-add-risk-etl-dag

3. Develop on the central dev server (SSH in → venv auto-activated)
   ssh alice@<DEVBOX_IP>
   cd ~/eq_tech

4. Test locally before pushing
   # Run Airflow DAG unit test
   airflow dags test daily_etl 2024-01-01

   # Run API tests
   pytest tests/

   # Lint
   ruff check apps/ data/

5. Push branch and open a Pull Request
   git push -u origin feat/EQ-42-add-risk-etl-dag
   # Open PR at https://github.com/ColumbiaDataScienceCorporation/eq_tech

6. PR passes automated checks (see Section 5)
   Code review by at least one team member

7. Squash-merge to main
   # GitHub Actions triggers the appropriate pipeline(s) automatically

8. Monitor the dev deployment in GitHub Actions tab
   # UAT and prod promotions require explicit approval (see Section 7)
```

---

## 4. CI/CD Pipeline Overview

There are **three pipelines** in `.github/workflows/`, each triggered by path filters on push to `main`. Only the pipeline(s) matching the changed paths run — unrelated environments are never touched.

### 4.1 Change Categories and Pipeline Triggers

| What changed | Path filter | Pipeline triggered | DAG auto-sync? |
|---|---|---|---|
| Airflow DAG Python files | `data/airflow/dags/**` | **None** | ✅ Yes – git-sync within 30 s |
| Airflow Docker base image | `data/airflow/docker/**` | `airflow-helm-deploy.yml` | No |
| Airflow Helm values (base or env overlay) | `infra/helm/airflow-values.yaml`, `infra/helm/airflow-values/**` | `airflow-helm-deploy.yml` | No |
| App source code or Dockerfile | `apps/**` | `apps-ci.yml` | No |
| Kubernetes manifests | `k8s/**` | `apps-ci.yml` | No |
| Terraform infrastructure | `infra/terraform/**` | `infra-ci.yml` | No |
| OAuth2 Proxy Helm values | `infra/helm/oauth2-proxy-values.yaml`, `infra/helm/oauth2-proxy-values/**` | Manual `workflow_dispatch` | No |

> **Rule of thumb:** If you only edit files under `data/airflow/dags/`, commit and push — no pipeline runs, no waiting, no approval needed. The change reaches `dev-airflow` within 30 seconds via git-sync.

### 4.2 `infra-ci.yml` — Terraform Infrastructure

Deploys changes to AKS cluster configuration, PostgreSQL SKU, ACR, and Key Vault.

```
push to main (infra/terraform/**)
        │
        ▼
  [deploy-dev]  ← environment: dev (auto-deploy, no gate)
        │  workspace: dev, var-file: environments/dev.tfvars
        │
        ▼ (after dev succeeds)
  [deploy-uat]  ← environment: uat (requires approval)
        │  workspace: uat, var-file: environments/uat.tfvars
        │
        ▼ (after uat succeeds)
  [deploy-prod] ← environment: prod (requires approval)
           workspace: prod, var-file: environments/prod.tfvars
```

### 4.3 `airflow-helm-deploy.yml` — Airflow Helm Upgrades

Runs `helm upgrade --install airflow-{env}` with base values layered with per-environment overrides.

```
push to main (infra/helm/airflow-values** or data/airflow/docker/**)
        │
        ▼
  [deploy-dev]   → helm upgrade airflow-dev --namespace dev-airflow
                   -f airflow-values.yaml -f airflow-values/dev.yaml
        │
        ▼ (approval gate)
  [deploy-uat]   → helm upgrade airflow-uat --namespace uat-airflow
                   -f airflow-values.yaml -f airflow-values/uat.yaml
        │
        ▼ (approval gate)
  [deploy-prod]  → helm upgrade airflow-prod --namespace prod-airflow
                   -f airflow-values.yaml -f airflow-values/prod.yaml
```

### 4.4 `apps-ci.yml` — Application Build and Deploy

Builds Docker images and deploys to environment namespaces sequentially.

```
push to main (apps/** or k8s/**)
        │
        ▼
  [build]       → az acr build for all 3 apps (api, ui-dash, ui-web)
                  pushes image:<sha> and image:latest to eqtechacr
        │
        ▼ (build must succeed)
  [deploy-dev]  ← environment: dev (auto-deploy)
        │         kubectl apply -n dev-apps
        │         kubectl set image -n dev-apps
        ▼ (approval gate)
  [deploy-uat]  ← environment: uat
        │         kubectl apply -n uat-apps
        │         kubectl set image -n uat-apps
        ▼ (approval gate)
  [deploy-prod] ← environment: prod
                  kubectl apply -n prod-apps
                  kubectl set image -n prod-apps
```

---

## 5. GitHub Environments Setup

GitHub Environments are what enforce the promotion gates. Create them in the GitHub UI before running any pipeline.

Navigate to: `https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings/environments`

### 5.1 `dev` Environment
- **Protection rules**: None — deploys automatically on every push to `main`
- **Deployment branches**: `main` only

### 5.2 `uat` Environment
- **Required reviewers**: Add 1–2 team leads or senior engineers
- **Wait timer**: Optional — 5 minutes gives time to cancel if dev issues appear immediately
- **Deployment branches**: `main` only
- **Effect**: Every `deploy-uat` job pauses and sends a notification to the required reviewers. Deployment proceeds only after an explicit approval click in the GitHub Actions UI.

### 5.3 `prod` Environment
- **Required reviewers**: Add 2 senior engineers or team lead + product owner (minimum 2)
- **Wait timer**: 10 minutes recommended (final opportunity to abort before live traffic is affected)
- **Deployment branches**: `main` only — prevents accidental prod deploys from a branch
- **Effect**: Identical to UAT approval gate but with stricter reviewer requirements.

### 5.4 Setting Reviewers via CLI

```bash
# These are REST API calls; paste your GitHub token
GITHUB_TOKEN=<PAT_WITH_REPO_ADMIN>
ORG=ColumbiaDataScienceCorporation
REPO=eq_tech

# UAT: set a single required reviewer (user login)
curl -X PUT \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  https://api.github.com/repos/$ORG/$REPO/environments/uat \
  -d '{"reviewers":[{"type":"User","id":<USER_ID>}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
```

---

## 6. Promotion Flow: dev → UAT → Prod

### 6.1 Normal Promotion (happy path)

```
Developer merges PR to main
         │
         ▼
GitHub Actions starts all matching pipelines
         │
         ▼
dev jobs run automatically (no human intervention)
         │
         ▼ dev deployment successful
         │
         ├── Developer verifies dev environment manually:
         │     https://dev.eq-tech.<LB_IP>.nip.io
         │     kubectl get pods -n dev-airflow
         │     airflow dags test <dag_id>  (on dev server)
         │
         ▼ Developer or tech lead clicks "Approve" for UAT in GitHub Actions UI
         │
uat jobs run
         │
         ▼ uat deployment successful
         │
         ├── QA / stakeholders verify UAT:
         │     https://uat.eq-tech.<LB_IP>.nip.io
         │     Run integration test suite
         │
         ▼ Tech lead + product owner click "Approve" for prod
         │
prod jobs run
         │
         ▼ prod deployment successful
```

### 6.2 Who Can Approve

| Stage | Who approves |
|---|---|
| dev → UAT | Any required reviewer listed on the `uat` GitHub Environment |
| UAT → prod | All required reviewers listed on the `prod` GitHub Environment must approve |

Approvals can be given in the GitHub Actions UI, the GitHub mobile app, or via email notification link.

### 6.3 Blocking a Promotion

To stop a deployment from proceeding to the next stage, click **"Reject"** on the pending approval. The pipeline job is cancelled; the merge commit remains on `main` but the deployment stays at its last successful stage. A new commit (fix or revert) is required to restart the pipeline.

---

## 7. Quality Gates

### 7.1 Pre-merge (PR checks)

Add the following as required status checks in the branch protection rules for `main`:

| Check | How to enforce |
|---|---|
| `ruff` linting | Add a `lint.yml` workflow triggered on `pull_request` that runs `ruff check .` |
| `pytest` unit tests | Add to the same `lint.yml` running `pytest tests/` |
| No secrets in diff | GitHub Advanced Security (GHAS) secret scanning — enabled automatically on GitHub Enterprise |
| At least 1 reviewer approval | Set in branch protection rules: "Require a pull request before merging" |

**`lint.yml`** (add to `.github/workflows/`):
```yaml
name: Lint and Test
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  lint-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - run: pip install ruff pytest
      - run: ruff check .
      - run: pytest tests/ -q --tb=short
```

### 7.2 Post-deploy Verification (dev)

After the dev pipeline deploys, the developer should run before approving UAT:

```bash
# On the central dev server
ssh alice@<DEVBOX_IP>

# API smoke test
curl -f https://dev.eq-tech.<LB_IP>.nip.io/api/healthz

# Airflow DAG parse check (no syntax errors)
kubectl exec -n dev-airflow \
  $(kubectl get pod -n dev-airflow -l component=scheduler -o name | head -1) \
  -- airflow dags list

# Check all pods are Running
kubectl get pods -n dev-airflow
kubectl get pods -n dev-apps
```

---

## 8. Rollback Procedures

### 8.1 Application Rollback (fast — < 5 minutes)

GitHub Actions image tags are pinned to `${{ github.sha }}`. To roll back to a previous version:

```bash
# Find the previous working SHA from git log
git log --oneline -10

# Roll back the image in the affected namespace
PREV_SHA=<previous_good_sha>
kubectl set image deployment/api \
  api=eqtechacr.azurecr.io/api:${PREV_SHA} \
  -n prod-apps

# Verify rollout
kubectl rollout status deployment/api -n prod-apps
```

Alternatively, use Kubernetes rollout history:
```bash
kubectl rollout undo deployment/api -n prod-apps
kubectl rollout undo deployment/dash-app -n prod-apps
```

### 8.2 Airflow Helm Rollback

```bash
# List revision history for the Airflow prod release
helm history airflow-prod -n prod-airflow

# Roll back to the previous Helm revision
helm rollback airflow-prod 0 -n prod-airflow  # 0 = previous revision
```

### 8.3 Terraform Rollback

Terraform doesn't have a single rollback command. The correct approach is to:

1. **Revert the change in code** with `git revert` on `main`
2. The reverted commit triggers `infra-ci.yml` again, which re-applies the previous state

For emergency manual rollback:
```bash
cd infra/terraform
terraform workspace select prod
terraform apply -var-file environments/prod.tfvars \
  -var "postgres_admin_password=<PASSWORD>"
# terraform applies whatever the code says — point the code to the previous state first
```

### 8.4 DAG Rollback

```bash
# Revert the DAG file on main
git revert <commit_that_broke_dag>
git push origin main
# git-sync picks up the revert within 30 seconds — no pipeline needed
```

---

## 9. Feature Flags

Use Airflow Variables or environment variables to hide incomplete work that has been merged to `main` but is not ready for UAT.

### Airflow Variable Flag (for DAGs)

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
# dev only — enable experimental DAG path
kubectl exec -n dev-airflow \
  $(kubectl get pod -n dev-airflow -l component=webserver -o name) \
  -- airflow variables set ENABLE_NEW_RISK_CALC true
```

### Pod Environment Variable Flag (for apps)

In the Kubernetes deployment manifest, set `FEATURE_NEW_PORTFOLIO_VIEW=false`. Override per environment using the Helm overlay:

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
| GitHub Fine-Grained PAT (git-sync) | GitHub Actions Secret (`GIT_SYNC_TOKEN`) reference only; actual value stored in K8s secret | `kubectl create secret` in Phase 13 Step 7 |
| OAuth2 Proxy client secret | GitHub Actions Secret (`OAUTH2_CLIENT_SECRET`) | `kubectl create secret oauth2-proxy-secret` in Phase 13 Step 7 |
| Azure credentials (Terraform/kubectl) | OIDC federation — no stored credential; short-lived token from Azure per job | `azure/login@v2` action |
| Dev server managed identity | Azure RBAC (system-assigned) | `az login --identity` inside the quota auto-scale script |

Rotate secrets by:
1. Updating the value in GitHub Secrets (`Settings → Secrets → Actions`)
2. Re-running the K8s secret creation command for the affected namespace(s)
3. Restarting the pods that consume the secret: `kubectl rollout restart deployment/<name> -n <ns>`
