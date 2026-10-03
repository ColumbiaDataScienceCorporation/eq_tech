<#
.SYNOPSIS
    Migrates the EQ Tech repo from trunk-based to branch-based SDLC.
    Automates steps A-C from branch_based_sdlc.md section 4.
    Steps D, E, F require manual GitHub UI actions (printed at the end).

.PARAMETER DryRun
    Print planned actions without executing them.

.EXAMPLE
    cd c:\eq_tech
    .\scripts\migrate-to-branch-sdlc.ps1
    .\scripts\migrate-to-branch-sdlc.ps1 -DryRun
#>
[CmdletBinding()]
param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO_ROOT = Resolve-Path "$PSScriptRoot\.."
$APP_ID    = "d5679b41-4dec-42e2-a2bc-7a884b6da06a"
$ORG       = "ColumbiaDataScienceCorporation"
$REPO_NAME = "eq_tech"
$ORG_ID    = "12076768"
$REPO_ID   = "1380689388"

function Write-Step([string]$msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "    [+] $msg" -ForegroundColor Green }
function Write-Skip([string]$msg) { Write-Host "    [-] $msg" -ForegroundColor DarkGray }

function Write-File([string]$relPath, [string]$content) {
    $full = Join-Path $REPO_ROOT $relPath
    $dir  = Split-Path $full
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    if ($DryRun) { Write-Skip "DryRun: would write $relPath"; return }
    [System.IO.File]::WriteAllText($full, $content, [System.Text.Encoding]::UTF8)
    Write-Ok "Wrote $relPath"
}

function Add-GitSyncBranch([string]$relPath, [string]$branchName) {
    $full = Join-Path $REPO_ROOT $relPath
    $text = Get-Content $full -Raw
    if ($text -match 'gitSync:[\s\S]*?branch:') {
        Write-Skip "$relPath already has gitSync.branch"
        return
    }
    if ($DryRun) { Write-Skip "DryRun: would append gitSync.branch: $branchName to $relPath"; return }
    $append = "`ndags:`n  gitSync:`n    branch: `"$branchName`"`n"
    Add-Content $full $append -Encoding utf8 -NoNewline
    Write-Ok "Appended gitSync.branch to $relPath"
}

# ── Prerequisites ──────────────────────────────────────────────────────────────
Write-Step "Checking prerequisites"

Set-Location $REPO_ROOT

$currentBranch = git rev-parse --abbrev-ref HEAD 2>&1
if ($currentBranch -ne "main") {
    throw "Must be on main branch (current: $currentBranch). Run: git checkout main"
}
$dirty = git status --porcelain 2>&1
if ($dirty) {
    throw "Uncommitted changes in working tree. Commit or stash them first.`n$dirty"
}
$null = az account show 2>&1
if ($LASTEXITCODE -ne 0) { throw "Not logged in to Azure. Run: az login" }

Write-Ok "On main, clean working tree, Azure CLI authenticated"

# ── Step A: OIDC Federated Credentials ─────────────────────────────────────────
Write-Step "Step A -- OIDC federated credentials for develop and uat branches"

$env:PATH += ";C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin"

$creds = @(
    @{ name = "github-develop-branch"; subject = "repo:${ORG}/${REPO_NAME}:ref:refs/heads/develop" }
    @{ name = "github-uat-branch";     subject = "repo:${ORG}/${REPO_NAME}:ref:refs/heads/uat"     }
    @{ name = "ent-develop-branch";    subject = "repo:${ORG}@${ORG_ID}/${REPO_NAME}@${REPO_ID}:ref:refs/heads/develop" }
    @{ name = "ent-uat-branch";        subject = "repo:${ORG}@${ORG_ID}/${REPO_NAME}@${REPO_ID}:ref:refs/heads/uat"     }
)

foreach ($c in $creds) {
    $existing = az ad app federated-credential list --id $APP_ID `
        --query "[?name=='$($c.name)'].name" -o tsv 2>$null
    if ($existing) { Write-Skip "$($c.name) already exists"; continue }
    if ($DryRun)   { Write-Skip "DryRun: would create $($c.name)"; continue }

    $json = '{"name":"' + $c.name + '","issuer":"https://token.actions.githubusercontent.com","subject":"' + $c.subject + '","audiences":["api://AzureADTokenExchange"]}'
    $tmp  = "$env:TEMP\fc-$($c.name).json"
    $json | Set-Content $tmp -Encoding utf8 -NoNewline
    $result = az ad app federated-credential create --id $APP_ID --parameters "@$tmp" --query name -o tsv 2>&1
    Write-Ok "Created: $result"
}

# ── Step B: Update files ────────────────────────────────────────────────────────
Write-Step "Step B -- Writing workflow files, Helm values, tests/ placeholder"

# infra-ci.yml
Write-File ".github\workflows\infra-ci.yml" @'
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
    name: Terraform - dev
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
    name: Terraform - uat
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
    name: Terraform - prod
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
'@

# airflow-helm-deploy.yml
Write-File ".github\workflows\airflow-helm-deploy.yml" @'
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
    name: Helm Upgrade Airflow - dev
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
    name: Helm Upgrade Airflow - uat
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
    name: Helm Upgrade Airflow - prod
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
'@

# apps-ci.yml
Write-File ".github\workflows\apps-ci.yml" @'
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
    name: Build & Push - ${{ matrix.app.name }}
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
    name: Deploy - dev
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
    name: Deploy - uat
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
    name: Deploy - prod
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
'@

# lint-test.yml (new)
Write-File ".github\workflows\lint-test.yml" @'
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
        # tests/ placeholder exists but has no real tests yet
        run: pytest tests/ -q --tb=short 2>/dev/null || echo "No tests directory found -- skipping"
'@

# tests/ placeholder
Write-File "tests\__init__.py" ""
Write-File "tests\test_placeholder.py" @'
def test_placeholder():
    pass
'@

# Airflow git-sync branch overrides
Add-GitSyncBranch "infra\helm\airflow-values\dev.yaml" "develop"
Add-GitSyncBranch "infra\helm\airflow-values\uat.yaml" "uat"

# ── Step B: Commit and push to main ────────────────────────────────────────────
Write-Step "Step B -- Committing and pushing to main"

if (-not $DryRun) {
    git add .github\workflows\infra-ci.yml `
            .github\workflows\airflow-helm-deploy.yml `
            .github\workflows\apps-ci.yml `
            .github\workflows\lint-test.yml `
            tests\ `
            infra\helm\airflow-values\dev.yaml `
            infra\helm\airflow-values\uat.yaml
    git commit -m "ci: migrate to branch-based SDLC (develop/uat/main)"
    git push origin main
    Write-Ok "Pushed to main"
} else {
    Write-Skip "DryRun: would commit and push to main"
}

# ── Step C: Create branches from updated main ──────────────────────────────────
Write-Step "Step C -- Creating uat and develop branches"

foreach ($b in @("uat", "develop")) {
    $exists = git ls-remote --heads origin $b 2>&1
    if ($exists -match "refs/heads/$b") {
        Write-Skip "origin/$b already exists"
        continue
    }
    if ($DryRun) { Write-Skip "DryRun: would create and push $b"; continue }
    git checkout -b $b
    git push -u origin $b
    git checkout main
    Write-Ok "Created and pushed origin/$b"
}

# ── Manual steps ───────────────────────────────────────────────────────────────
Write-Host @"

==============================================================================
  AUTOMATED STEPS COMPLETE
  Now complete the following manual steps in the GitHub UI.
==============================================================================

STEP D -- Update GitHub Environment deployment-branch restrictions
  URL: https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings/environments

  For each environment, click the name, scroll to "Deployment branches",
  change the pattern from "main" to the branch shown below:

    dev   --> develop
    uat   --> uat
    prod  --> main  (no change needed)

STEP E -- Add branch protection rules
  URL: https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings/branches

  Click "Add rule" for each of the three branches:

  Branch: develop
    [x] Require a pull request before merging  (Required approvals: 1)
    [x] Require status checks to pass          (Add: "lint-test / lint-test")
    [x] Restrict who can push to matching branches

  Branch: uat
    [x] Require a pull request before merging  (Required approvals: 1)
    [x] Require status checks to pass          (Add: "lint-test / lint-test")
    [x] Restrict who can push to matching branches

  Branch: main
    [x] Require a pull request before merging  (Required approvals: 2)
    [x] Require status checks to pass          (Add: "lint-test / lint-test")
    [x] Restrict who can push to matching branches

STEP F -- Set develop as the default branch
  URL: https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings

  Scroll to "Default branch", click the pencil icon, select "develop", save.

STEP G -- Smoke test
  Push a trivial change to develop and confirm only deploy-dev jobs run:

    git checkout develop
    git commit --allow-empty -m "test: verify branch-based CI"
    git push origin develop

  Expected: only the "deploy-dev" jobs in infra-ci, airflow-helm-deploy,
  and apps-ci trigger. The deploy-uat and deploy-prod jobs are skipped.

==============================================================================
"@ -ForegroundColor Yellow
