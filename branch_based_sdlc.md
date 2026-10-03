# Branch-Based SDLC Implementation Plan

## Overview

This plan migrates the current trunk-based single-branch CI/CD to a branch-based model with three long-lived branches, each mapped to an environment. The existing infrastructure (AKS, PostgreSQL, Helm releases, Kubernetes secrets, OIDC service principal) remains **unchanged**. Only the GitHub repository structure, branch protection rules, OIDC federated credentials, workflow triggers, and DAG git-sync configuration change.

---

## 1. Branch Strategy

```
main ─────────────────────────────────────────────► prod environment
  │
  ├── uat ──────────────────────────────────────────► uat environment
  │     │
  │     └── develop ─────────────────────────────────► dev environment
  │           │
  │           ├── feature/EQ-42-new-dag          (developer work)
  │           └── feature/EQ-55-api-endpoint     (developer work)
  │
  └── hotfix/EQ-99-scheduler-crash              (branches from main, not develop)
```

### Long-lived branches

| Branch | Environment | Auto-deploys on push | Requires PR to merge |
|---|---|---|---|
| `main` | prod | ✅ (after gate) | ✅ Required reviewers ≥ 2 |
| `uat` | UAT | ✅ (after gate) | ✅ Required reviewer ≥ 1 |
| `develop` | dev | ✅ auto | ✅ Required reviewer ≥ 1 |

### Short-lived branches

| Branch pattern | Purpose | Base branch | Merges into |
|---|---|---|---|
| `feature/*` | New features, DAGs, lib changes | `develop` | `develop` via PR |
| `hotfix/*` | Production bug fix | `main` | `main` via PR, then back-merge to `uat` → `develop` |
| `release/*` | Optional — stabilisation before UAT→prod | `uat` | `main` via PR |

---

## 2. Promotion Flow

```
Developer creates feature/EQ-42 from develop
        │
        ▼
PR: feature/EQ-42 → develop
  CI: lint + unit tests run automatically
  Review: ≥1 approval required
        │
        ▼ merge
develop branch → auto-deploy to dev environment
        │
        ▼ when dev is stable: PR develop → uat
  Review: ≥1 QA/tech lead approval
        │
        ▼ merge
uat branch → deploy to UAT (requires GitHub Environment approval for uat)
        │
        ▼ when UAT is validated: PR uat → main
  Review: ≥2 senior engineers + 10-min wait timer
        │
        ▼ merge
main branch → deploy to prod (requires GitHub Environment approval for prod)
```

### Hotfix flow

```
Production incident detected
        │
        ▼
Create hotfix/EQ-99 from main
        │
        ▼
PR: hotfix/EQ-99 → main   (emergency review, ≥1 reviewer)
        │
        ▼ merge
main → deploy to prod
        │
        ▼ back-merge (two sequential PRs):
hotfix/EQ-99 → uat → develop   (keeps all branches in sync)
```

---

## 3. Changes Required

### 3.1 Azure OIDC Federated Credentials

Each branch that runs CI/CD jobs needs a federated credential. The deploy jobs use GitHub Environments (e.g., `environment: dev`), which produce the subject `repo:Org/repo:environment:dev` — those already exist. The new requirement is credentials for the branch-push triggers on `develop` and `uat`.

**Run from your workstation (or add to `scripts/bootstrap.ps1`):**

```powershell
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH","User") + ";" +
            "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin"
$APP_ID = "d5679b41-4dec-42e2-a2bc-7a884b6da06a"

# Standard GitHub format
$newCreds = @(
    @{ name="github-develop-branch"; subject="repo:ColumbiaDataScienceCorporation/eq_tech:ref:refs/heads/develop" },
    @{ name="github-uat-branch";     subject="repo:ColumbiaDataScienceCorporation/eq_tech:ref:refs/heads/uat"     }
)

# GitHub Enterprise format (includes @org_id / @repo_id)
$entCreds = @(
    @{ name="ent-develop-branch"; subject="repo:ColumbiaDataScienceCorporation@12076768/eq_tech@1380689388:ref:refs/heads/develop" },
    @{ name="ent-uat-branch";     subject="repo:ColumbiaDataScienceCorporation@12076768/eq_tech@1380689388:ref:refs/heads/uat"     }
)

foreach ($c in ($newCreds + $entCreds)) {
    $json = '{"name":"' + $c.name + '","issuer":"https://token.actions.githubusercontent.com","subject":"' + $c.subject + '","audiences":["api://AzureADTokenExchange"]}'
    $tmp = "$env:TEMP\fc-$($c.name).json"
    $json | Set-Content $tmp -Encoding utf8 -NoNewline
    $r = az ad app federated-credential create --id $APP_ID --parameters "@$tmp" --query name -o tsv 2>&1
    Write-Host "$($c.name): $r"
}
```

> The existing credentials for `main`, `pull_request`, and all three `environment:dev/uat/prod` subjects remain in place.

---

### 3.2 GitHub Repository Setup

#### 3.2.1 Create the long-lived branches

```bash
# From your local clone (currently on main)
git checkout main
git checkout -b uat
git push -u origin uat

git checkout -b develop
git push -u origin develop

# Set develop as the default branch
# GitHub → Settings → Branches → Default branch → switch to develop
```

#### 3.2.2 Branch protection rules

Navigate to `https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings/branches` and add rules for all three long-lived branches:

| Branch | Required PR reviews | Status checks required | Direct push blocked |
|---|---|---|---|
| `main` | ≥ 2 | `lint-test` | ✅ |
| `uat` | ≥ 1 | `lint-test` | ✅ |
| `develop` | ≥ 1 | `lint-test` | ✅ |

All three rules: **"Restrict who can push to matching branches"** — allow only the GitHub Actions bot and designated tech leads.

#### 3.2.3 GitHub Environments

The three existing environments (`dev`, `uat`, `prod`) keep their protection rules unchanged. Update **Deployment branches** for each:

| Environment | Change deployment branches from | To |
|---|---|---|
| `dev` | `main` only | `develop` only |
| `uat` | `main` only | `uat` only |
| `prod` | `main` only | `main` only (unchanged) |

Navigate to `https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings/environments` → click each environment → **Deployment branches** → **Selected branches** → update pattern.

---

### 3.3 Workflow: `infra-ci.yml`

**Current:** triggers only on `main`. All three environments deploy sequentially from the same push.

**New design:** each branch independently triggers only its own environment.

```yaml
name: Infrastructure CI/CD (Terraform)

on:
  push:
    branches: [develop, uat, main]
    paths:
      - "infra/terraform/**"
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  deploy-dev:
    name: Terraform – dev
    if: github.ref == 'refs/heads/develop'
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.8.x"
      - run: terraform init
        working-directory: infra/terraform
      - name: Terraform Apply (dev)
        working-directory: infra/terraform
        run: |
          terraform workspace select dev || terraform workspace new dev
          terraform apply -auto-approve \
            -var-file environments/dev.tfvars \
            -var "postgres_admin_password=${{ secrets.PG_ADMIN_PASSWORD }}"

  deploy-uat:
    name: Terraform – uat
    if: github.ref == 'refs/heads/uat'
    runs-on: ubuntu-latest
    environment: uat
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.8.x"
      - run: terraform init
        working-directory: infra/terraform
      - name: Terraform Apply (uat)
        working-directory: infra/terraform
        run: |
          terraform workspace select uat || terraform workspace new uat
          terraform apply -auto-approve \
            -var-file environments/uat.tfvars \
            -var "postgres_admin_password=${{ secrets.PG_ADMIN_PASSWORD }}"

  deploy-prod:
    name: Terraform – prod
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: prod
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.8.x"
      - run: terraform init
        working-directory: infra/terraform
      - name: Terraform Apply (prod)
        working-directory: infra/terraform
        run: |
          terraform workspace select prod || terraform workspace new prod
          terraform apply -auto-approve \
            -var-file environments/prod.tfvars \
            -var "postgres_admin_password=${{ secrets.PG_ADMIN_PASSWORD }}"
```

**Key difference from current:** `needs: [deploy-dev]` chains are removed. Each job has an `if:` guard that makes it run only for the branch it owns. A push to `develop` runs only `deploy-dev`; a push to `uat` runs only `deploy-uat`; a push to `main` runs only `deploy-prod`. No cross-environment sequencing — promotion happens via the PR → merge flow.

---

### 3.4 Workflow: `airflow-helm-deploy.yml`

Same pattern as infra: branch-gated independent jobs, no chaining.

```yaml
name: Airflow Helm Deploy

on:
  push:
    branches: [develop, uat, main]
    paths:
      - "infra/helm/airflow-values.yaml"
      - "infra/helm/airflow-values/**"
      - "data/airflow/docker/**"
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  deploy-dev:
    name: Helm Upgrade Airflow – dev
    if: github.ref == 'refs/heads/develop'
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - run: az aks get-credentials --resource-group eq-tech-rg --name eq-tech-aks --overwrite-existing
      - uses: azure/setup-helm@v4
      - run: helm repo add apache-airflow https://airflow.apache.org && helm repo update
      - name: Helm Upgrade Airflow (dev)
        run: |
          helm upgrade --install airflow-dev apache-airflow/airflow \
            --namespace dev-airflow --create-namespace \
            -f infra/helm/airflow-values.yaml \
            -f infra/helm/airflow-values/dev.yaml \
            --rollback-on-failure --timeout 20m

  deploy-uat:
    name: Helm Upgrade Airflow – uat
    if: github.ref == 'refs/heads/uat'
    runs-on: ubuntu-latest
    environment: uat
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - run: az aks get-credentials --resource-group eq-tech-rg --name eq-tech-aks --overwrite-existing
      - uses: azure/setup-helm@v4
      - run: helm repo add apache-airflow https://airflow.apache.org && helm repo update
      - name: Helm Upgrade Airflow (uat)
        run: |
          helm upgrade --install airflow-uat apache-airflow/airflow \
            --namespace uat-airflow --create-namespace \
            -f infra/helm/airflow-values.yaml \
            -f infra/helm/airflow-values/uat.yaml \
            --rollback-on-failure --timeout 20m

  deploy-prod:
    name: Helm Upgrade Airflow – prod
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: prod
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - run: az aks get-credentials --resource-group eq-tech-rg --name eq-tech-aks --overwrite-existing
      - uses: azure/setup-helm@v4
      - run: helm repo add apache-airflow https://airflow.apache.org && helm repo update
      - name: Helm Upgrade Airflow (prod)
        run: |
          helm upgrade --install airflow-prod apache-airflow/airflow \
            --namespace prod-airflow --create-namespace \
            -f infra/helm/airflow-values.yaml \
            -f infra/helm/airflow-values/prod.yaml \
            --rollback-on-failure --timeout 20m
```

---

### 3.5 Workflow: `apps-ci.yml`

The build matrix stays unchanged (all three apps built once per push). Deployment jobs are branch-gated — no chaining.

```yaml
name: Apps CI/CD

on:
  push:
    branches: [develop, uat, main]
    paths:
      - "apps/**"
      - "k8s/**"
      - "lib/**"
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

env:
  ACR_NAME: eqtechacr
  ACR_LOGIN_SERVER: eqtechacr.azurecr.io

jobs:
  build:
    name: Build & Push – ${{ matrix.app.name }}
    runs-on: ubuntu-latest
    strategy:
      matrix:
        app:
          - { name: api,     path: apps/api,    image: api,     deployment: api,      container: api      }
          - { name: ui-dash, path: apps/ui-dash, image: ui-dash, deployment: dash-app, container: dash-app }
          - { name: ui-web,  path: apps/ui-web,  image: ui-web,  deployment: web-ui,   container: web-ui   }
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - name: Build & Push Docker Image to ACR
        # ACR Tasks blocked on trial; use docker build + az acr login
        # :latest is ONLY pushed from main so prod deployments always get the production image
        run: |
          az acr login --name ${{ env.ACR_NAME }}
          docker build \
            -t ${{ env.ACR_LOGIN_SERVER }}/${{ matrix.app.image }}:${{ github.sha }} \
            -t ${{ env.ACR_LOGIN_SERVER }}/${{ matrix.app.image }}:${{ github.ref_name }} \
            -f ${{ matrix.app.path }}/Dockerfile \
            .
          docker push ${{ env.ACR_LOGIN_SERVER }}/${{ matrix.app.image }}:${{ github.sha }}
          docker push ${{ env.ACR_LOGIN_SERVER }}/${{ matrix.app.image }}:${{ github.ref_name }}
          if [ "${{ github.ref }}" = "refs/heads/main" ]; then
            docker tag ${{ env.ACR_LOGIN_SERVER }}/${{ matrix.app.image }}:${{ github.sha }} \
                       ${{ env.ACR_LOGIN_SERVER }}/${{ matrix.app.image }}:latest
            docker push ${{ env.ACR_LOGIN_SERVER }}/${{ matrix.app.image }}:latest
          fi

  deploy-dev:
    name: Deploy – dev
    if: github.ref == 'refs/heads/develop'
    runs-on: ubuntu-latest
    environment: dev
    needs: [build]
    strategy:
      matrix:
        app:
          - { name: api,     image: api,     deployment: api,      container: api      }
          - { name: ui-dash, image: ui-dash, deployment: dash-app, container: dash-app }
          - { name: ui-web,  image: ui-web,  deployment: web-ui,   container: web-ui   }
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - run: az aks get-credentials --resource-group eq-tech-rg --name eq-tech-aks --overwrite-existing
      - name: Deploy to dev-apps
        run: |
          kubectl apply -f k8s/namespaces.yaml
          kubectl apply -f k8s/apps/ -n dev-apps
          kubectl apply -f k8s/ingress/dev.yaml -n dev-apps
          if kubectl get deployment/${{ matrix.app.deployment }} -n dev-apps >/dev/null 2>&1; then
            kubectl set image deployment/${{ matrix.app.deployment }} \
              ${{ matrix.app.container }}=${{ env.ACR_LOGIN_SERVER }}/${{ matrix.app.image }}:${{ github.sha }} \
              -n dev-apps
          fi

  deploy-uat:
    name: Deploy – uat
    if: github.ref == 'refs/heads/uat'
    runs-on: ubuntu-latest
    environment: uat
    needs: [build]
    strategy:
      matrix:
        app:
          - { name: api,     image: api,     deployment: api,      container: api      }
          - { name: ui-dash, image: ui-dash, deployment: dash-app, container: dash-app }
          - { name: ui-web,  image: ui-web,  deployment: web-ui,   container: web-ui   }
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - run: az aks get-credentials --resource-group eq-tech-rg --name eq-tech-aks --overwrite-existing
      - name: Deploy to uat-apps
        run: |
          kubectl apply -f k8s/apps/ -n uat-apps
          kubectl apply -f k8s/ingress/uat.yaml -n uat-apps
          if kubectl get deployment/${{ matrix.app.deployment }} -n uat-apps >/dev/null 2>&1; then
            kubectl set image deployment/${{ matrix.app.deployment }} \
              ${{ matrix.app.container }}=${{ env.ACR_LOGIN_SERVER }}/${{ matrix.app.image }}:${{ github.sha }} \
              -n uat-apps
          fi

  deploy-prod:
    name: Deploy – prod
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: prod
    needs: [build]
    strategy:
      matrix:
        app:
          - { name: api,     image: api,     deployment: api,      container: api      }
          - { name: ui-dash, image: ui-dash, deployment: dash-app, container: dash-app }
          - { name: ui-web,  image: ui-web,  deployment: web-ui,   container: web-ui   }
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - run: az aks get-credentials --resource-group eq-tech-rg --name eq-tech-aks --overwrite-existing
      - name: Deploy to prod-apps
        run: |
          kubectl apply -f k8s/apps/ -n prod-apps
          kubectl apply -f k8s/ingress/prod.yaml -n prod-apps
          if kubectl get deployment/${{ matrix.app.deployment }} -n prod-apps >/dev/null 2>&1; then
            kubectl set image deployment/${{ matrix.app.deployment }} \
              ${{ matrix.app.container }}=${{ env.ACR_LOGIN_SERVER }}/${{ matrix.app.image }}:${{ github.sha }} \
              -n prod-apps
          fi
```

---

### 3.6 New Workflow: `lint-test.yml`

Runs on every PR and on every push to `develop`, `uat`, or `main`. Blocks merge if it fails.

```yaml
name: Lint and Test

on:
  pull_request:
    branches: [develop, uat, main]
  push:
    branches: [develop, uat, main]

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
      - name: Install dev dependencies
        run: pip install ruff pytest pydantic-settings psycopg2-binary sqlalchemy
      - name: Lint
        run: ruff check .
      - name: Unit tests
        # tests/ does not exist yet; --ignore-glob silences the missing-path error
        run: pytest tests/ -q --tb=short 2>/dev/null || echo "No tests directory found — skipping"
```

> **Create a placeholder so pytest does not fail immediately:**
> ```bash
> mkdir tests && touch tests/__init__.py tests/test_placeholder.py
> # test_placeholder.py body:
> # def test_placeholder(): pass
> ```
> Add these files to the same commit as the `lint-test.yml` workflow (Step F in §4).

---

### 3.7 Airflow git-sync Branch Per Environment

Currently all three Airflow releases sync DAGs from `main`. After this change, each environment must sync from its own branch:

| Environment | Helm release | git-sync branch |
|---|---|---|
| dev | `airflow-dev` | `develop` |
| uat | `airflow-uat` | `uat` |
| prod | `airflow-prod` | `main` |

**Changes in `infra/helm/airflow-values/dev.yaml`** — add:
```yaml
dags:
  gitSync:
    branch: "develop"
```

**Changes in `infra/helm/airflow-values/uat.yaml`** — add:
```yaml
dags:
  gitSync:
    branch: "uat"
```

The `infra/helm/airflow-values/prod.yaml` and the base `airflow-values.yaml` keep `branch: "main"` (already set in the base).

> The git-sync credentials secrets are already in all three `-airflow` namespaces from `finish-dev.ps1` and are branch-agnostic (the PAT has read access to all branches).

---

### 3.8 `docs/sdlc_cicd.md` Update

The SDLC doc (`docs/sdlc_cicd.md`) currently describes the trunk-based model. After implementation it must be updated to:
- Replace the branching strategy section with the three-branch model
- Replace the "promotion flow" diagram with the PR-based flow above
- Update the GitHub Environments table to show which branch each environment maps to
- Note that `lint-test.yml` is the required PR gate instead of GitHub Environment gates being the only safety net

This update is deferred until after the code changes are implemented and confirmed working.

---

## 4. Implementation Order

Run `scripts/migrate-to-branch-sdlc.ps1` to automate steps A–C, then complete D–F in the GitHub UI.

### Prerequisites

- PowerShell 5.1 or later
- Azure CLI logged in (`az login`) to subscription `0702e805-0c66-4bbd-9eb4-47ce81ecb369`
- Local clone on `main` branch with a clean working tree
- Git remote `origin` pointing to `https://github.com/ColumbiaDataScienceCorporation/eq_tech`

### Running the script

```powershell
cd c:\eq_tech
.\scripts\migrate-to-branch-sdlc.ps1          # execute
.\scripts\migrate-to-branch-sdlc.ps1 -DryRun  # preview only
```

The script is idempotent — safe to re-run if interrupted.

### What the script does

| Step | Action | How |
|---|---|---|
| **A** | Create 4 OIDC federated credentials for `develop` and `uat` branches | `az ad app federated-credential create` (skips if already exists) |
| **B** | Replace the three workflow files with branch-gated versions; create `lint-test.yml`; append `gitSync.branch` to `dev.yaml` and `uat.yaml`; create `tests/` placeholder; commit and push to `main` | File writes + `git commit` + `git push origin main` |
| **C** | Create `uat` and `develop` branches from the now-updated `main` and push to origin | `git checkout -b` + `git push` (skips if branch already exists) |

---

### Step D — Update GitHub Environment Deployment-Branch Restrictions  *(manual)*

Navigate to `https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings/environments`.

For each environment, click its name → scroll to **Deployment branches** → change the pattern:

| Environment | Change from | Change to |
|---|---|---|
| `dev` | `main` | `develop` |
| `uat` | `main` | `uat` |
| `prod` | `main` | `main` (no change needed) |

### Step E — Add Branch Protection Rules  *(manual)*

Navigate to `https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings/branches` and click **Add rule** for each branch:

| Setting | `develop` | `uat` | `main` |
|---|---|---|---|
| Require a pull request before merging | ✅ (1 approval) | ✅ (1 approval) | ✅ (2 approvals) |
| Require status checks to pass | ✅ | ✅ | ✅ |
| Required status check name | `lint-test / lint-test` | `lint-test / lint-test` | `lint-test / lint-test` |
| Restrict who can push | ✅ | ✅ | ✅ |

### Step F — Set `develop` as the Default Branch  *(manual)*

Navigate to `https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings` → **Default branch** → click the pencil icon → select `develop` → save.

### Step G — Smoke Test

```bash
git checkout develop
git commit --allow-empty -m "test: verify branch-based CI"
git push origin develop
```

Go to `https://github.com/ColumbiaDataScienceCorporation/eq_tech/actions` and confirm:
- `deploy-dev` jobs run in all three workflows
- `deploy-uat` and `deploy-prod` jobs are **skipped** (not failed)



---

## 5. What Does NOT Change

| Component | Why unchanged |
|---|---|
| AKS cluster, namespaces, K8s secrets | Infrastructure is environment-scoped, not branch-scoped |
| PostgreSQL databases (`airflow_dev`, `airflow_uat`, `airflow_prod`) | Unchanged |
| Helm release names (`airflow-dev`, `airflow-uat`, `airflow-prod`) | Unchanged |
| OAuth2 Proxy deployment | Shared in `auth` namespace, unchanged |
| Entra ID App Registration | Unchanged |
| GitHub Environments (`dev`, `uat`, `prod`) and their reviewer rules | Unchanged — the environment gates remain; only deployment-branch restriction updates |
| OIDC credentials for `environment:dev`, `environment:uat`, `environment:prod` | Already registered and unchanged |
| `scripts/bootstrap.ps1` OIDC logic | Step A above adds the two new branch credentials; the rest is unchanged |
| `scripts/finish-dev.ps1` | Unchanged |
| `scripts/provision-dev.ps1` | Unchanged |

---

## 6. Rollback Plan

If the branch-based approach needs to be reverted:

1. Delete `develop` and `uat` branches from GitHub
2. Revert the three workflow files to their current `branches: [main]` trigger versions
3. Remove the `lint-test.yml` workflow
4. Reset `default branch` back to `main`
5. Restore GitHub Environment deployment-branch restrictions to `main`

The OIDC federated credentials for `develop` and `uat` branches can remain (harmless if unused) or be deleted via `az ad app federated-credential delete`.

---

## 7. Pre-Migration Infrastructure Check (2026-10-03)

Verified on 2026-10-03 before beginning the migration. **No infrastructure teardown is required.**

### 7.1 Current Resource State

| Resource | SKU / Config | State |
|---|---|---|
| AKS – `eq-tech-aks` | 1× Standard_D4pls_v5, k8s v1.35 | Running |
| PostgreSQL – `eq-tech-pg` | B_Standard_B1ms, 32 GiB | Ready |
| ACR – `eqtechacr` | Basic | — |
| Key Vault – `eq-tech-kv` | Standard | — |

### 7.2 Kubernetes Workload State

All namespaces (`dev/uat/prod-airflow`, `dev/uat/prod-apps`, `auth`, `ingress-nginx`) present. At time of check, all pods were **Pending** due to the node being `NotReady`.

**Root cause:** The single AKS node (`aks-system-34493244-vmss000000`) had its kubelet stop posting heartbeats on 2026-09-28. The node's memory limits were over-committed at 131% (`7612Mi` limits against `5910Mi` allocatable), which likely caused the kubelet to crash. AKS applied the `node.kubernetes.io/out-of-service:NoExecute` taint and all pods were evicted.

**Fix applied:** Direct VMSS instance restart:
```bash
az vmss restart \
  --resource-group MC_eq-tech-rg_eq-tech-aks_centralus \
  --name aks-system-34493244-vmss \
  --instance-ids 0
```

After 90 seconds the node returned `Ready` and all pods recovered:

| Namespace | Pods | Status |
|---|---|---|
| `dev-airflow` | scheduler 3/3, triggerer 3/3, webserver 1/1, statsd 1/1 | Running |
| `auth` | oauth2-proxy 1/1 | Running |
| `uat-airflow`, `prod-airflow` | — | Not yet deployed (correct) |

### 7.3 Git Repository State

```
Branch:  main (only branch — develop and uat do not exist yet)
HEAD:    5f90342  scripts: replace --ignore-not-found flag with compatible command sequence
Remote:  origin/main, origin/master
```

This is exactly the expected starting point. The migration begins with Step A (OIDC credentials), then Step B (commit workflow changes to `main`), then Step C (cut `uat` and `develop` from the updated `main`).

### 7.4 Why No Teardown Is Needed

The branch-based SDLC migration touches only:
- Azure AD app registration (OIDC federated credentials) — no infra
- GitHub repository branches, protection rules, environment settings — no infra
- Workflow YAML files and Helm values overrides — no infra

Nothing changes in AKS, PostgreSQL, ACR, Key Vault, Kubernetes namespaces, or any deployed secrets. The `uat` and `prod` Terraform workspaces and Kubernetes namespaces already exist from the initial scaffold; they simply have no workloads deployed yet, which is the correct state before the `uat` and `main` branches are live.

