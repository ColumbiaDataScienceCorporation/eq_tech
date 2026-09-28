# EQ Tech Platform – Implementation Plan

## Account Context

| Resource               | Value                                                         |
| ---------------------- | ------------------------------------------------------------- |
| Azure Subscription ID  | `0702e805-0c66-4bbd-9eb4-47ce81ecb369`                      |
| Azure Tenant ID        | `e5e33b11-e89c-466a-bf06-e94151676845`                      |
| Azure Tenant Domain    | `jinxin1hotmail.onmicrosoft.com`                            |
| GitHub Enterprise Repo | `https://github.com/ColumbiaDataScienceCorporation/eq_tech` |
| GitHub Org             | `ColumbiaDataScienceCorporation`                            |

---

## Architecture Overview

```
[ GitHub Enterprise: ColumbiaDataScienceCorporation/eq_tech ]
        │
        ├── GitHub Actions (CI/CD via OIDC – no stored credentials)
        │
        ├─► [ Azure Container Registry: eqtechacr ]
        │         └── Docker images: api, ui-dash, ui-web
        │
        ├─► [ AKS Cluster: eq-tech-aks ]
        │      │
        │      ├── Namespaces: {dev,uat,prod}-airflow
        │      │    ├── Airflow Webserver  (behind OAuth2 Proxy)
        │      │    ├── Airflow Scheduler  (git-sync sidecar → pulls DAGs from repo)
        │      │    └── Worker Pods        (KubernetesExecutor – spin up per task)
        │      │
        │      ├── Namespaces: {dev,uat,prod}-apps
        │      │    ├── FastAPI Microservice    (/api/*)
        │      │    ├── Dash Application        (/dash/*)
        │      │    └── Web UI (Nginx)           (/)
        │      │
        │      └── Namespace: auth  (shared – one OAuth2 Proxy for all envs)
        │           └── OAuth2 Proxy (Entra ID OIDC SSO + group header injection)
        │
        ├─► [ Azure Database for PostgreSQL ] (Airflow metadata backend)
        ├─► [ Azure Key Vault ]              (Secrets store)
        └─► [ Dev Server: eq-tech-devbox (Azure VM) ]
               ├── Shared Python venv  (/opt/eq-tech/venv, auto-activated on login)
               └── Per-user disk quotas (auto-scaling cron every 15 min)
```

**Authentication flow for every request:**

```
Browser → NGINX Ingress → OAuth2 Proxy → Entra ID (OIDC login)
                                ↓ (200 OK + X-Auth-Request-Groups header)
                         Downstream Pod (FastAPI / Dash / Airflow Webserver)
                                ↓ (app-level RBAC via group header)
```

---

## Monorepo Directory Layout

Create the following structure inside `https://github.com/ColumbiaDataScienceCorporation/eq_tech`:

```
eq_tech/
├── .github/
│   └── workflows/
│       ├── infra-ci.yml                # Terraform: AKS, PostgreSQL, ACR, Key Vault
│       ├── airflow-helm-deploy.yml     # Helm: Deploy/upgrade Airflow on AKS
│       └── apps-ci.yml                 # Build Docker images & deploy apps to AKS
├── apps/
│   ├── api/                            # FastAPI microservice
│   │   ├── main.py
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   ├── ui-dash/                        # Plotly Dash application
│   │   ├── app.py
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   └── ui-web/                         # Static web UI (Nginx)
│       ├── index.html
│       └── Dockerfile
├── data/
│   └── airflow/
│       ├── dags/                       # Synced live by git-sync – no rebuild needed
│       │   ├── hello_world_dag.py
│       │   ├── daily_etl_dag.py
│       │   └── k8s_pod_operator_dag.py
│       └── docker/                     # Optional custom Airflow worker base image
│           └── Dockerfile
├── infra/
│   ├── helm/
│   │   ├── airflow-values.yaml         # Base Airflow Helm values (all envs inherit)
│   │   ├── airflow-values/             # Per-environment Helm overrides
│   │   │   ├── dev.yaml
│   │   │   ├── uat.yaml
│   │   │   └── prod.yaml
│   │   ├── oauth2-proxy-values.yaml    # Base OAuth2 Proxy Helm values
│   │   └── oauth2-proxy-values/        # Per-environment Helm overrides
│   │       ├── dev.yaml
│   │       ├── uat.yaml
│   │       └── prod.yaml
│   └── terraform/
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── environments/               # Per-env tfvars (committed – no secrets inside)
│           ├── dev.tfvars
│           ├── uat.tfvars
│           └── prod.tfvars
├── k8s/
│   ├── namespaces.yaml
│   ├── apps/
│   │   ├── api-deployment.yaml
│   │   ├── dash-deployment.yaml
│   │   └── web-deployment.yaml
│   └── ingress/
│       ├── dev.yaml
│       ├── uat.yaml
│       └── prod.yaml
├── lib/                                        # Shared library – imported by all apps and DAGs
│   ├── config/
│   │   └── settings.py                         # Pydantic Settings: env-aware credentials & config
│   ├── db/
│   │   ├── postgres.py                         # SQLAlchemy engine + session context-manager
│   │   ├── snowflake_client.py                 # Snowflake SQLAlchemy engine
│   │   └── models/
│   │       ├── base.py                         # Declarative base shared by all ORM models
│   │       └── portfolio.py                    # PortfolioPosition ORM model
│   ├── auth/
│   │   └── groups.py                           # AD group auth: FastAPI dep + Flask hook
│   ├── logging/
│   │   └── structured.py                       # JSON-structured logger (Azure Monitor ready)
│   ├── storage/
│   │   └── azure_blob.py                       # Azure Blob Storage client (workload identity)
│   ├── calendar/
│   │   └── trading_calendar.py                 # US market business-day utilities
│   ├── market_data/
│   │   └── client.py                           # Abstract market data interface + CSV/REST adapters
│   ├── notifications/
│   │   └── teams.py                            # Microsoft Teams webhook alerts
│   └── portfolio/
│       └── metrics.py                          # Returns, vol, Sharpe, VaR, drawdown, position summary
│                                               # (add further business logic modules here)
├── requirements/
│   ├── dev.txt                         # Installed on the central dev server shared venv
│   ├── api.txt                         # Mirror of apps/api/requirements.txt
│   └── dash.txt                        # Mirror of apps/ui-dash/requirements.txt
├── scripts/
│   ├── bootstrap.ps1                   # Automates Steps 2–4: Terraform backend, OIDC SP, Entra ID app reg
│   └── provision-dev.ps1               # Automates Step 7: Terraform apply, NGINX Ingress, namespaces, LB IP
├── pyproject.toml                      # Project metadata + tool config (ruff, pytest)
└── .gitignore
```

### `.gitignore` (root)

```
infra/terraform/.terraform/
infra/terraform/*.tfstate
infra/terraform/*.tfstate.backup
infra/terraform/tfplan
.venv/
__pycache__/
*.pyc
*.egg-info/
.ruff_cache/
.pytest_cache/
```

### `pyproject.toml` (root)

```toml
[project]
name = "eq-tech"
version = "0.1.0"
requires-python = ">=3.11"

[tool.ruff]
line-length = 100
target-version = "py311"

[tool.ruff.lint]
select = ["E", "F", "I"]

[tool.pytest.ini_options]
testpaths = ["tests"]
```

### `requirements/dev.txt`

This file defines every dependency installed in the **shared venv on the central dev server**. It spans all sub-projects so developers can run, test, and author code from any part of the monorepo without switching environments.

```
# Airflow + Kubernetes provider (matches Helm-deployed version)
apache-airflow==2.11.0
apache-airflow-providers-cncf-kubernetes>=8.0.0

# API
fastapi==0.111.0
uvicorn[standard]==0.29.0
httpx>=0.27.0

# Dash
dash==2.17.0
plotly==5.22.0
gunicorn==22.0.0

# Kubernetes client (for DAG authoring and local testing)
kubernetes>=29.0.0

# lib/config
pydantic-settings>=2.3.0

# lib/db
psycopg2-binary>=2.9.9
sqlalchemy>=2.0.30
snowflake-sqlalchemy>=1.6.0

# lib/storage
azure-storage-blob>=12.20.0
azure-identity>=1.17.0

# lib/market_data (CSV/parquet handling)
pandas>=2.2.0

# Dev tooling
pytest>=8.0.0
ruff>=0.4.0
ipython>=8.0.0
pre-commit>=3.7.0
```

---

## Phase 1: Prerequisites – Local Tooling

Install on your workstation (Windows):

```powershell
winget install --id Microsoft.AzureCLI
winget install --id Helm.Helm
winget install --id Hashicorp.Terraform

# kubectl via Azure CLI
az aks install-cli
```

Login to Azure:

```bash
az login
az account set --subscription 0702e805-0c66-4bbd-9eb4-47ce81ecb369
```

---

## Phase 2: Infrastructure Provisioning (Terraform)

### Bootstrap Terraform State Storage (run once, manually)

```bash
az group create --name eq-tech-tfstate-rg --location eastus

az storage account create \
  --name eqtechtfstate \
  --resource-group eq-tech-tfstate-rg \
  --location eastus \
  --sku Standard_LRS \
  --kind StorageV2

az storage container create \
  --name tfstate \
  --account-name eqtechtfstate
```

### `infra/terraform/variables.tf`

```hcl
variable "subscription_id" {
  default = "0702e805-0c66-4bbd-9eb4-47ce81ecb369"
}

variable "tenant_id" {
  default = "e5e33b11-e89c-466a-bf06-e94151676845"
}

variable "location" {
  default = "centralus"  # eastus is blocked for PostgreSQL Flexible Server on trial
}

variable "resource_group" {
  default = "eq-tech-rg"
}

variable "aks_cluster_name" {
  default = "eq-tech-aks"
}

variable "acr_name" {
  # Must be globally unique, lowercase alphanumeric only
  default = "eqtechacr"
}

variable "postgres_server_name" {
  default = "eq-tech-pg"
}

variable "postgres_admin_user" {
  default = "airflow_admin"
}

variable "postgres_admin_password" {
  sensitive = true
}

variable "keyvault_name" {
  default = "eq-tech-kv"
}

variable "environment" {
  description = "Deployment environment: dev, uat, or prod"
  type        = string
  default     = "dev"
}

variable "aks_node_count" {
  description = "Number of AKS system nodes"
  type        = number
  default     = 2
}

variable "aks_vm_size" {
  description = "AKS node VM size"
  type        = string
  # B-series not available in centralus on trial; D4pls_v5 is available and cost-effective
  default     = "Standard_D4pls_v5"
}

variable "postgres_sku" {
  description = "PostgreSQL Flexible Server SKU"
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "PostgreSQL storage in MB"
  type        = number
  default     = 32768
}
```

### `infra/terraform/main.tf`

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
  backend "azurerm" {
    resource_group_name  = "eq-tech-tfstate-rg"
    storage_account_name = "eqtechtfstate"
    container_name       = "tfstate"
    key                  = "eq-tech.tfstate"
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group
  location = var.location
}

# Azure Container Registry
resource "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false
}

# AKS Cluster (D4pls_v5 – available on trial; ALS required for all versions in centralus)
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks_cluster_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "eq-tech"
  kubernetes_version  = "1.35"
  support_plan        = "AKSLongTermSupport"

  default_node_pool {
    name       = "system"
    node_count = var.aks_node_count
    vm_size    = var.aks_vm_size
  }

  identity {
    type = "SystemAssigned"
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true
}

# Grant AKS kubelet identity permission to pull images from ACR
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.acr.id
  skip_service_principal_aad_check = true
}

# PostgreSQL Flexible Server – Airflow metadata backend
resource "azurerm_postgresql_flexible_server" "pg" {
  name                   = var.postgres_server_name
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  version                = "15"
  administrator_login    = var.postgres_admin_user
  administrator_password = var.postgres_admin_password
  storage_mb             = var.postgres_storage_mb
  sku_name               = var.postgres_sku
  zone                   = "1"  # must be explicitly set to prevent immutable zone drift on re-apply        = 7
  geo_redundant_backup_enabled = false
}

resource "azurerm_postgresql_flexible_server_database" "airflow" {
  name      = "airflow_${var.environment}"
  server_id = azurerm_postgresql_flexible_server.pg.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Firewall rule: allow all IPs for trial (restrict to AKS egress IP in production)
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "255.255.255.255"
}

# Key Vault
resource "azurerm_key_vault" "kv" {
  name                = var.keyvault_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  access_policy {
    tenant_id = var.tenant_id
    object_id = data.azurerm_client_config.current.object_id
    secret_permissions = ["Get", "Set", "List", "Delete", "Purge"]
  }
}
```

### `infra/terraform/outputs.tf`

```hcl
output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.pg.fqdn
}

output "keyvault_uri" {
  value = azurerm_key_vault.kv.vault_uri
}
```

### Terraform Environment Files

`environments/` files contain non-sensitive configuration and **are committed to the repo**. The PostgreSQL password is always passed via `-var` in CI and never stored in these files.

**`infra/terraform/environments/dev.tfvars`**

```hcl
# Trial-grade: minimal resources
# B-series not available in centralus on trial; D4pls_v5 (ARM, 4 vCPU, 8 GB) is available
environment         = "dev"
aks_node_count      = 1
aks_vm_size         = "Standard_D4pls_v5"
postgres_sku        = "B_Standard_B1ms"
postgres_storage_mb = 32768
location            = "centralus"
```

**`infra/terraform/environments/uat.tfvars`**

```hcl
environment         = "uat"
aks_node_count      = 2
aks_vm_size         = "Standard_D4ps_v5"
postgres_sku        = "B_Standard_B2ms"
postgres_storage_mb = 65536
location            = "centralus"
```

**`infra/terraform/environments/prod.tfvars`**

```hcl
environment         = "prod"
aks_node_count      = 3
aks_vm_size         = "Standard_D4s_v6"
postgres_sku        = "GP_Standard_D2s_v3"
postgres_storage_mb = 131072
location            = "centralus"
```

### Terraform Workspace Setup and Apply

Terraform workspaces isolate state per environment while sharing `main.tf`. Create workspaces once, then select the appropriate one per apply. For the trial only the `dev` workspace is required.

```bash
cd infra/terraform
terraform init

# Create workspaces once
terraform workspace new dev
terraform workspace new uat
terraform workspace new prod

# Deploy dev
terraform workspace select dev
terraform apply \
  -var-file environments/dev.tfvars \
  -var "postgres_admin_password=<YOUR_PASSWORD>"
```

---

## Phase 3: GitHub Actions OIDC Federation (Secretless Auth)

OIDC federation lets GitHub Actions authenticate to Azure with short-lived tokens – no stored passwords.

### 3.1 Create Service Principal and Federated Credentials

```bash
# Create the app registration
APP_ID=$(az ad app create --display-name "github-actions-eq-tech" --query appId -o tsv)
SP_OBJECT_ID=$(az ad sp create --id $APP_ID --query id -o tsv)

# Contributor on the subscription (for Terraform + AKS + ACR management)
az role assignment create \
  --role Contributor \
  --assignee $SP_OBJECT_ID \
  --scope /subscriptions/0702e805-0c66-4bbd-9eb4-47ce81ecb369

# AcrPush on the registry — required for GitHub Actions docker push
az role assignment create \
  --role AcrPush \
  --assignee $SP_OBJECT_ID \
  --scope /subscriptions/0702e805-0c66-4bbd-9eb4-47ce81ecb369/resourceGroups/eq-tech-rg/providers/Microsoft.ContainerRegistry/registries/eqtechacr

# NOTE: GitHub Enterprise generates OIDC subjects with org_id and repo_id embedded:
#   repo:Org@{org_id}/repo@{repo_id}:ref:refs/heads/main
# AND environment-scoped jobs use :environment:<name> as the subject.
# Register ALL required variants so every job type can authenticate.

# Standard GitHub.com format (ref/branch and environments)
for SUBJ in \
  "repo:ColumbiaDataScienceCorporation/eq_tech:ref:refs/heads/main" \
  "repo:ColumbiaDataScienceCorporation/eq_tech:pull_request" \
  "repo:ColumbiaDataScienceCorporation/eq_tech:environment:dev" \
  "repo:ColumbiaDataScienceCorporation/eq_tech:environment:uat" \
  "repo:ColumbiaDataScienceCorporation/eq_tech:environment:prod"; do
  NAME=$(echo $SUBJ | tr ':/' '-' | sed 's/^repo-/github-/')
  cat > /tmp/fc.json << EOF
{"name":"$NAME","issuer":"https://token.actions.githubusercontent.com","subject":"$SUBJ","audiences":["api://AzureADTokenExchange"]}
EOF
  az ad app federated-credential create --id $APP_ID --parameters @/tmp/fc.json --query name -o tsv 2>/dev/null || true
done

# GitHub Enterprise format (replace 12076768 with your org ID, 1380689388 with your repo ID
# — read from the "subject claim" in a failed workflow run log)
for SUBJ in \
  "repo:ColumbiaDataScienceCorporation@12076768/eq_tech@1380689388:ref:refs/heads/main" \
  "repo:ColumbiaDataScienceCorporation@12076768/eq_tech@1380689388:pull_request" \
  "repo:ColumbiaDataScienceCorporation@12076768/eq_tech@1380689388:environment:dev" \
  "repo:ColumbiaDataScienceCorporation@12076768/eq_tech@1380689388:environment:uat" \
  "repo:ColumbiaDataScienceCorporation@12076768/eq_tech@1380689388:environment:prod"; do
  NAME=$(echo $SUBJ | sed 's/[^a-zA-Z0-9]/-/g' | cut -c1-60)
  cat > /tmp/fc.json << EOF
{"name":"ent-$NAME","issuer":"https://token.actions.githubusercontent.com","subject":"$SUBJ","audiences":["api://AzureADTokenExchange"]}
EOF
  az ad app federated-credential create --id $APP_ID --parameters @/tmp/fc.json --query name -o tsv 2>/dev/null || true
done

echo "AZURE_CLIENT_ID = $APP_ID"
```

### 3.2 GitHub Repository Secrets

Navigate to `https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings/secrets/actions` and add:

| Secret Name               | Value                                                             |
| ------------------------- | ----------------------------------------------------------------- |
| `AZURE_CLIENT_ID`       | Output of`$APP_ID` above                                        |
| `AZURE_TENANT_ID`       | `e5e33b11-e89c-466a-bf06-e94151676845`                          |
| `AZURE_SUBSCRIPTION_ID` | `0702e805-0c66-4bbd-9eb4-47ce81ecb369`                          |
| `PG_ADMIN_PASSWORD`     | Strong password for PostgreSQL (16+ chars)                        |
| `GIT_SYNC_TOKEN`        | GitHub Fine-Grained PAT with read-only`Contents` on `eq_tech` |
| `OAUTH2_CLIENT_ID`      | Entra ID App Client ID (set up in Phase 4)                        |
| `OAUTH2_CLIENT_SECRET`  | Entra ID App Client Secret (set up in Phase 4)                    |

---

## Phase 4: Entra ID App Registration for OAuth2 Proxy

### 4.1 Determine Your Ingress IP First

Before creating the app registration, you need the LoadBalancer IP to set the redirect URI. Install NGINX Ingress first (Phase 5, step 5.3), then come back to update the redirect URI.

Use a placeholder redirect URI now and update it once the IP is known:

```bash
# Create the OAuth2 Proxy app registration
OAUTH_APP_ID=$(az ad app create \
  --display-name "eq-tech-oauth2-proxy" \
  --web-redirect-uris "https://placeholder.example.com/oauth2/callback" \
  --query appId -o tsv)

# Create a client secret (copy this – it is shown only once)
OAUTH_SECRET=$(az ad app credential reset \
  --id $OAUTH_APP_ID \
  --display-name "oauth2-proxy-secret" \
  --query password -o tsv)

echo "OAUTH2_CLIENT_ID  = $OAUTH_APP_ID"
echo "OAUTH2_CLIENT_SECRET = $OAUTH_SECRET"
```

### 4.2 Enable Security Groups Claim in the ID Token

```bash
az ad app update --id $OAUTH_APP_ID --set groupMembershipClaims=SecurityGroup
```

Or in the Azure Portal:

1. **Entra ID → App Registrations → eq-tech-oauth2-proxy**
2. **Token configuration → Add groups claim → Security groups → Save**

### 4.3 Grant Microsoft Graph Permissions and Admin Consent

```bash
# openid, profile, email delegated permissions on Microsoft Graph
az ad app permission add \
  --id $OAUTH_APP_ID \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions \
    37f7f235-527c-4136-accd-4a02d197296e=Scope \
    14dad69e-099b-42c9-810b-d002981feec1=Scope \
    64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0=Scope

az ad app permission admin-consent --id $OAUTH_APP_ID
```

### 4.4 Update Redirect URI After Getting Ingress IP

Once you have `<LB_IP>` from Phase 5 step 5.3:

```bash
az ad app update \
  --id $OAUTH_APP_ID \
  --web-redirect-uris \
    "https://dev.eq-tech.<LB_IP>.nip.io/oauth2/callback" \
    "https://uat.eq-tech.<LB_IP>.nip.io/oauth2/callback" \
    "https://eq-tech.<LB_IP>.nip.io/oauth2/callback"
```

---

## Phase 5: Kubernetes Cluster Setup

### 5.1 Get AKS Credentials

```bash
az aks get-credentials \
  --resource-group eq-tech-rg \
  --name eq-tech-aks \
  --overwrite-existing
```

### 5.2 Create Namespaces

**`k8s/namespaces.yaml`**

```yaml
# auth is shared – one OAuth2 Proxy instance serves all environments
apiVersion: v1
kind: Namespace
metadata:
  name: auth
---
# dev
apiVersion: v1
kind: Namespace
metadata:
  name: dev-airflow
---
apiVersion: v1
kind: Namespace
metadata:
  name: dev-apps
---
# uat
apiVersion: v1
kind: Namespace
metadata:
  name: uat-airflow
---
apiVersion: v1
kind: Namespace
metadata:
  name: uat-apps
---
# prod
apiVersion: v1
kind: Namespace
metadata:
  name: prod-airflow
---
apiVersion: v1
kind: Namespace
metadata:
  name: prod-apps
```

```bash
kubectl apply -f k8s/namespaces.yaml
```

### 5.3 Install NGINX Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=1

# Wait for the external IP assignment (takes 1-2 minutes)
kubectl get svc -n ingress-nginx ingress-nginx-controller --watch
```

Note the `EXTERNAL-IP` value (e.g. `20.1.2.3`). Your platform domain becomes:
`https://eq-tech.20.1.2.3.nip.io`

Replace every occurrence of `<LB_IP>` in this document with that IP address.

### 5.4 Create Kubernetes Secrets

Run after Terraform outputs the PostgreSQL FQDN:

```bash
PG_FQDN=$(terraform -chdir=infra/terraform output -raw postgres_fqdn)

# Create one set of Airflow secrets per environment (different DB name per env)
for ENV in dev uat prod; do
  kubectl create secret generic airflow-postgres-secret \
    --namespace ${ENV}-airflow \
    --from-literal=connection="postgresql+psycopg2://airflow_admin:<PG_PASSWORD>@${PG_FQDN}/airflow_${ENV}"

  # git-sync credential: same PAT, replicated per-namespace
  # Airflow 2.11+ chart uses git-sync v4 (GITSYNC_*); include v3 keys too for older chart versions
  kubectl create secret generic github-git-sync-token \
    --namespace ${ENV}-airflow \
    --from-literal=GIT_SYNC_USERNAME=x-access-token \
    --from-literal=GIT_SYNC_PASSWORD=<GITHUB_FINE_GRAINED_PAT> \
    --from-literal=GITSYNC_USERNAME=x-access-token \
    --from-literal=GITSYNC_PASSWORD=<GITHUB_FINE_GRAINED_PAT>
done

# OAuth2 Proxy secret (shared across all envs in the auth namespace)
COOKIE_SECRET=$(python3 -c "import secrets, base64; print(base64.b64encode(secrets.token_bytes(16)).decode())")
kubectl create secret generic oauth2-proxy-secret \
  --namespace auth \
  --from-literal=client-id=<OAUTH2_CLIENT_ID> \
  --from-literal=client-secret=<OAUTH2_CLIENT_SECRET> \
  --from-literal=cookie-secret=$COOKIE_SECRET
```

---

## Phase 6: Deploy OAuth2 Proxy

**`infra/helm/oauth2-proxy-values.yaml`**

Replace `<LB_IP>` before deploying. The tenant ID is already set.

```yaml
# The chart reads client-id, client-secret, and cookie-secret keys from this secret
existingSecret: oauth2-proxy-secret

extraArgs:
  provider: oidc
  oidc-issuer-url: "https://login.microsoftonline.com/e5e33b11-e89c-466a-bf06-e94151676845/v2.0"
  redirect-url: "https://eq-tech.<LB_IP>.nip.io/oauth2/callback"
  scope: "openid profile email"
  email-domain: "*"
  upstream: "file:///dev/null"
  http-address: "0.0.0.0:4180"
  pass-user-headers: "true"
  pass-access-token: "true"
  set-xauthrequest: "true"

service:
  type: ClusterIP
  port: 4180

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: "eq-tech.<LB_IP>.nip.io"
      paths:
        - path: /oauth2
          pathType: Prefix
```

```bash
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests
helm repo update

helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy \
  --namespace auth \
  -f infra/helm/oauth2-proxy-values.yaml \
  -f infra/helm/oauth2-proxy-values/dev.yaml
```

---

## Phase 7: Deploy Self-Managed Airflow

**`infra/helm/airflow-values.yaml`**

Replace `<LB_IP>` before deploying.

```yaml
airflowVersion: "2.11.0"
images:
  airflow:
    repository: apache/airflow
    tag: "2.11.0"
    pullPolicy: IfNotPresent

executor: "KubernetesExecutor"

# Use external Azure PostgreSQL – disable bundled Postgres
postgresql:
  enabled: false

data:
  metadataSecretName: "airflow-postgres-secret"

# git-sync: automatically pulls DAGs from the monorepo every 30 seconds
dags:
  gitSync:
    enabled: true
    repo: "https://github.com/ColumbiaDataScienceCorporation/eq_tech.git"
    branch: "main"
    subPath: "data/airflow/dags"
    depth: 1
    wait: 30
    credentialsSecret: "github-git-sync-token"

# Webserver exposed only within the cluster – NGINX Ingress + OAuth2 Proxy handles external access
webserver:
  service:
    type: ClusterIP
  defaultUser:
    enabled: true
    role: Admin
    username: admin
    email: jin_xin1@hotmail.com
    firstName: Jin
    lastName: Xin
    password: "ChangeMe123!"

scheduler:
  resources:
    requests:
      cpu: "500m"
      memory: "512Mi"
    limits:
      cpu: "1"
      memory: "1Gi"

workers:
  serviceAccount:
    create: true

# Set base URL so all Airflow-generated links use the /airflow sub-path correctly
config:
  webserver:
    base_url: "https://eq-tech.<LB_IP>.nip.io/airflow"

# Ingress protected by OAuth2 Proxy (auth-url annotation triggers the external-auth flow)
ingress:
  web:
    enabled: true
    ingressClassName: nginx
    annotations:
      # auth-url must include :4180 port — oauth2-proxy service listens on 4180, not 80
      nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.auth.svc.cluster.local:4180/oauth2/auth"
      nginx.ingress.kubernetes.io/auth-signin: "https://eq-tech.<LB_IP>.nip.io/oauth2/start?rd=$escaped_request_uri"
      nginx.ingress.kubernetes.io/auth-response-headers: "X-Auth-Request-User, X-Auth-Request-Email, X-Auth-Request-Groups"
    hosts:
      - name: "eq-tech.<LB_IP>.nip.io"
        tls:
          enabled: false
    path: "/airflow"
```

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update

helm upgrade --install airflow apache-airflow/airflow \
  --namespace dev-airflow \
  --create-namespace \
  -f infra/helm/airflow-values.yaml \
  -f infra/helm/airflow-values/dev.yaml \
  --timeout 10m \
  --atomic
```

---

## Phase 7b: Environment-Specific Helm Value Overrides

Each `infra/helm/airflow-values/<env>.yaml` is passed as a **second `-f` flag** to `helm upgrade`, layering environment-specific settings on top of `airflow-values.yaml`. Only keys that differ from the base need to be listed.

**`infra/helm/airflow-values/dev.yaml`** – minimal resources for the trial

```yaml
scheduler:
  resources:
    requests: { cpu: "250m", memory: "256Mi" }
    limits:   { cpu: "500m", memory: "512Mi" }
webserver:
  resources:
    requests: { cpu: "250m", memory: "256Mi" }
    limits:   { cpu: "500m", memory: "512Mi" }
config:
  webserver:
    base_url: "https://dev.eq-tech.<LB_IP>.nip.io/airflow"
ingress:
  web:
    hosts:
      - name: "dev.eq-tech.<LB_IP>.nip.io"
    path: "/airflow"
```

**`infra/helm/airflow-values/uat.yaml`** – production-like sizing

```yaml
scheduler:
  resources:
    requests: { cpu: "500m", memory: "512Mi" }
    limits:   { cpu: "1",     memory: "1Gi"   }
webserver:
  resources:
    requests: { cpu: "250m", memory: "256Mi" }
    limits:   { cpu: "500m", memory: "512Mi" }
config:
  webserver:
    base_url: "https://uat.eq-tech.<LB_IP>.nip.io/airflow"
ingress:
  web:
    hosts:
      - name: "uat.eq-tech.<LB_IP>.nip.io"
    path: "/airflow"
```

**`infra/helm/airflow-values/prod.yaml`** – full resources

```yaml
scheduler:
  resources:
    requests: { cpu: "1",     memory: "1Gi"   }
    limits:   { cpu: "2",     memory: "2Gi"   }
webserver:
  resources:
    requests: { cpu: "500m", memory: "512Mi" }
    limits:   { cpu: "1",     memory: "1Gi"   }
config:
  webserver:
    base_url: "https://eq-tech.<LB_IP>.nip.io/airflow"
ingress:
  web:
    hosts:
      - name: "eq-tech.<LB_IP>.nip.io"
    path: "/airflow"
```

**`infra/helm/oauth2-proxy-values/dev.yaml`** – dev callback

```yaml
extraArgs:
  redirect-url: "https://dev.eq-tech.<LB_IP>.nip.io/oauth2/callback"
ingress:
  hosts:
    - host: "dev.eq-tech.<LB_IP>.nip.io"
      paths:
        - path: /oauth2
          pathType: Prefix
```

> `uat.yaml` and `prod.yaml` follow the same pattern with `uat.eq-tech.<LB_IP>.nip.io` and `eq-tech.<LB_IP>.nip.io` respectively.

---

## Phase 8: Example Airflow DAGs

These files live in `data/airflow/dags/` and are automatically loaded by git-sync — no container rebuild or Helm redeploy is needed when you add or edit DAGs.

### `data/airflow/dags/hello_world_dag.py`

```python
from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator

default_args = {
    "owner": "eq-tech",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="hello_world",
    description="Validates Airflow is running correctly on AKS",
    schedule="@daily",
    start_date=datetime(2024, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["example"],
) as dag:

    greet = BashOperator(
        task_id="greet",
        bash_command="echo 'Hello from EQ Tech Airflow on AKS! Run ID: {{ run_id }}'",
    )

    def log_context(**kwargs):
        print(f"DAG run ID    : {kwargs['run_id']}")
        print(f"Logical date  : {kwargs['logical_date']}")
        print(f"Executor type : KubernetesExecutor")

    log = PythonOperator(
        task_id="log_context",
        python_callable=log_context,
    )

    greet >> log
```

### `data/airflow/dags/daily_etl_dag.py`

```python
from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator

default_args = {
    "owner": "eq-tech",
    "retries": 2,
    "retry_delay": timedelta(minutes=10),
    "email_on_failure": False,
}


def extract(**kwargs):
    """Simulates pulling price data from a source system."""
    data = {
        "symbols": ["AAPL", "MSFT", "GOOG"],
        "prices":  [185.50, 415.20, 175.80],
    }
    kwargs["ti"].xcom_push(key="raw_data", value=data)
    print(f"Extracted {len(data['symbols'])} symbols")


def transform(**kwargs):
    """Computes simple daily returns from extracted prices."""
    raw = kwargs["ti"].xcom_pull(key="raw_data", task_ids="extract")
    baseline = 180.0
    returns = {
        sym: round((price - baseline) / baseline, 4)
        for sym, price in zip(raw["symbols"], raw["prices"])
    }
    kwargs["ti"].xcom_push(key="returns", value=returns)
    print(f"Computed returns: {returns}")


def load(**kwargs):
    """Simulates writing transformed data to a target store."""
    returns = kwargs["ti"].xcom_pull(key="returns", task_ids="transform")
    # In production: write to Azure Blob Storage or PostgreSQL
    print(f"Loaded {len(returns)} return records to data store")
    for sym, ret in returns.items():
        print(f"  {sym}: {ret:+.2%}")


with DAG(
    dag_id="daily_etl",
    description="Daily ETL: extract → transform → load",
    schedule="0 6 * * 1-5",  # weekdays at 06:00 UTC
    start_date=datetime(2024, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["etl", "daily"],
) as dag:

    t_extract   = PythonOperator(task_id="extract",   python_callable=extract)
    t_transform = PythonOperator(task_id="transform", python_callable=transform)
    t_load      = PythonOperator(task_id="load",      python_callable=load)

    t_extract >> t_transform >> t_load
```

### `data/airflow/dags/k8s_pod_operator_dag.py`

```python
from datetime import datetime, timedelta
from airflow import DAG
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from kubernetes.client import models as k8s

default_args = {
    "owner": "eq-tech",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="k8s_pod_example",
    description="Runs an isolated compute task in a dedicated Kubernetes Pod",
    schedule="@weekly",
    start_date=datetime(2024, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["kubernetes", "example"],
) as dag:

    risk_compute = KubernetesPodOperator(
        task_id="risk_compute_pod",
        name="risk-compute-pod",
        namespace="dev-airflow",
        # Any image from ACR or public registry can be used here
        image="python:3.11-slim",
        cmds=["python", "-c"],
        arguments=[
            "import math; "
            "portfolio = [0.02, -0.01, 0.03, -0.005, 0.015]; "
            "vol = math.sqrt(sum(r**2 for r in portfolio) / len(portfolio)); "
            "print(f'Portfolio daily volatility: {vol:.4f}')"
        ],
        resources=k8s.V1ResourceRequirements(
            requests={"cpu": "250m", "memory": "256Mi"},
            limits={"cpu": "500m", "memory": "512Mi"},
        ),
        is_delete_operator_pod=True,
        get_logs=True,
    )
```

---

## Phase 9: Application Code

### 9.1 FastAPI Microservice

**`apps/api/requirements.txt`**

```
fastapi==0.111.0
uvicorn[standard]==0.29.0
# lib dependencies (already in the shared venv on the dev server)
pydantic-settings>=2.3.0
psycopg2-binary>=2.9.9
sqlalchemy>=2.0.30
```

**`apps/api/main.py`**

```python
from datetime import date

from fastapi import Depends, FastAPI, Request

from lib.auth.groups import get_request_email, get_request_user, require_groups
from lib.config.settings import get_settings
from lib.db.models import PortfolioPosition, init_db
from lib.db.postgres import get_db_session, health_check as pg_health
from lib.logging.structured import get_logger
from lib.portfolio.metrics import summarise_positions

log = get_logger(__name__)
settings = get_settings()

app = FastAPI(title="EQ Tech API", version="1.0.0")


@app.on_event("startup")
def startup() -> None:
    """Create DB tables on startup if they don't exist yet."""
    init_db()
    log.info("API started", environment=settings.environment.value)


@app.get("/healthz")
def health_check():
    """Liveness probe – unauthenticated."""
    return {"status": "healthy", "db": "ok" if pg_health() else "unreachable"}


@app.get("/api/v1/me")
def whoami(request: Request):
    """Returns the authenticated user's identity and group memberships."""
    return {
        "user":   get_request_user(request),
        "email":  get_request_email(request),
        "groups": request.headers.get("X-Auth-Request-Groups", "").split(","),
    }


@app.get("/api/v1/portfolio")
def get_portfolio(
    request: Request,
    portfolio_id: str = "P001",
    # Requires caller to be in the analysts OR admins Entra group
    _groups=require_groups(settings.analysts_group_id, settings.admins_group_id),
):
    """
    Returns live portfolio positions from PostgreSQL and computes a summary.
    Uses lib.db for DB access, lib.auth for group gate, lib.portfolio for analytics.
    """
    with get_db_session() as session:
        rows = (
            session.query(PortfolioPosition)
            .filter(
                PortfolioPosition.portfolio_id == portfolio_id,
                PortfolioPosition.as_of_date == date.today(),
            )
            .all()
        )

    if not rows:
        # Return synthetic data when the table is empty (demo / first run)
        positions = [
            {"portfolio_id": portfolio_id, "symbol": "AAPL", "quantity": 100,
             "cost_basis": 150.0, "market_price": 185.5},
            {"portfolio_id": portfolio_id, "symbol": "MSFT", "quantity": 50,
             "cost_basis": 300.0, "market_price": 415.2},
            {"portfolio_id": portfolio_id, "symbol": "GOOG", "quantity": 75,
             "cost_basis": 140.0, "market_price": 175.8},
        ]
    else:
        positions = [
            {
                "portfolio_id": r.portfolio_id,
                "symbol": r.symbol,
                "quantity": r.quantity,
                "cost_basis": r.cost_basis,
                "market_price": r.market_price,
            }
            for r in rows
        ]

    summary = summarise_positions(positions)
    log.info("Portfolio retrieved",
             user=get_request_user(request),
             portfolio_id=portfolio_id,
             num_positions=len(positions))
    return {
        "portfolio_id": summary.portfolio_id,
        "total_market_value": summary.total_market_value,
        "unrealised_pnl": summary.unrealised_pnl,
        "unrealised_pnl_pct": summary.unrealised_pnl_pct,
        "positions": summary.positions,
    }
```

**`apps/api/Dockerfile`**

Built from the **repo root** so `lib/` is available inside the image.

```dockerfile
FROM python:3.11-slim
WORKDIR /app
# Copy shared library first (cached layer if lib is unchanged)
COPY lib/ lib/
COPY apps/api/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY apps/api/ apps/api/
ENV PYTHONPATH=/app
EXPOSE 8000
CMD ["uvicorn", "apps.api.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

---

### 9.2 Dash Application

**`apps/ui-dash/requirements.txt`**

```
dash==2.17.0
plotly==5.22.0
gunicorn==22.0.0
pydantic-settings>=2.3.0
```

**`apps/ui-dash/app.py`**

```python
import dash
from dash import dcc, html
import plotly.graph_objects as go

from lib.auth.groups import FlaskGroupAuth
from lib.config.settings import get_settings

app = dash.Dash(__name__, title="EQ Tech Analytics")
settings = get_settings()

# Enforce AD group membership before every non-exempt request
auth = FlaskGroupAuth(settings.analysts_group_id, settings.admins_group_id)
app.server.before_request(auth.before_request)


@app.server.route("/healthz")
def healthz():
    return "OK", 200


fig = go.Figure(go.Pie(
    labels=["AAPL", "MSFT", "GOOG", "AMZN"],
    values=[0.30, 0.25, 0.20, 0.25],
    hole=0.4,
))
fig.update_layout(title_text="Portfolio Allocation")

app.layout = html.Div([
    html.H1("EQ Tech Analytics Dashboard"),
    dcc.Graph(figure=fig),
])

server = app.server  # Expose Flask server for gunicorn

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8050, debug=False)
```

**`apps/ui-dash/Dockerfile`**

Built from the **repo root** so `lib/` is available inside the image.

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY lib/ lib/
COPY apps/ui-dash/requirements.txt requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY apps/ui-dash/app.py app.py
ENV PYTHONPATH=/app
EXPOSE 8050
CMD ["gunicorn", "app:server", "--bind", "0.0.0.0:8050", "--workers", "2"]
```

---

### 9.3 Static Web UI

**`apps/ui-web/index.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>EQ Tech Platform</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 40px; background: #f4f6f9; color: #333; }
    h1   { color: #0078d4; }
    nav a { margin-right: 24px; text-decoration: none; color: #0078d4; font-weight: bold; }
    .card { background: white; padding: 24px; border-radius: 8px; margin-top: 24px;
            box-shadow: 0 2px 6px rgba(0,0,0,0.1); max-width: 640px; }
  </style>
</head>
<body>
  <h1>EQ Tech Platform</h1>
  <nav>
    <a href="/dash/">Analytics Dashboard</a>
    <a href="/api/v1/me">My Profile</a>
    <a href="/airflow/">Airflow</a>
  </nav>
  <div class="card">
    <h2>Welcome</h2>
    <p>You are authenticated via Microsoft Entra ID. Select a module above to get started.</p>
  </div>
</body>
</html>
```

**`apps/ui-web/Dockerfile`**

```dockerfile
FROM nginx:alpine
# Build context is repo root; path must be relative to it
COPY apps/ui-web/index.html /usr/share/nginx/html/index.html
EXPOSE 80
```

---

## Phase 10: Kubernetes Manifests

### `k8s/apps/api-deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: eqtechacr.azurecr.io/api:latest
          ports:
            - containerPort: 8000
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 30
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: api-service
spec:
  selector:
    app: api
  ports:
    - port: 8000
      targetPort: 8000
  type: ClusterIP
```

### `k8s/apps/dash-deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dash-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dash-app
  template:
    metadata:
      labels:
        app: dash-app
    spec:
      containers:
        - name: dash-app
          image: eqtechacr.azurecr.io/ui-dash:latest
          ports:
            - containerPort: 8050
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8050
            initialDelaySeconds: 15
            periodSeconds: 30
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: dash-service
spec:
  selector:
    app: dash-app
  ports:
    - port: 8050
      targetPort: 8050
  type: ClusterIP
```

### `k8s/apps/web-deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-ui
  template:
    metadata:
      labels:
        app: web-ui
    spec:
      containers:
        - name: web-ui
          image: eqtechacr.azurecr.io/ui-web:latest
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
            limits:
              cpu: "250m"
              memory: "128Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: web-service
spec:
  selector:
    app: web-ui
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
```

### `k8s/ingress/dev.yaml` / `uat.yaml` / `prod.yaml`

Each file is identical in structure; only the `host` and `auth-signin` URL differ per environment. Replace `<LB_IP>` before applying.

```yaml
# k8s/ingress/dev.yaml  (uat.yaml and prod.yaml follow the same pattern)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: eq-tech-ingress
  annotations:
    nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.auth.svc.cluster.local/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "https://dev.eq-tech.<LB_IP>.nip.io/oauth2/start?rd=$escaped_request_uri"
    nginx.ingress.kubernetes.io/auth-response-headers: "X-Auth-Request-User, X-Auth-Request-Email, X-Auth-Request-Groups"
spec:
  ingressClassName: nginx
  rules:
    - host: "dev.eq-tech.<LB_IP>.nip.io"
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-service
                port:
                  number: 8000
          - path: /dash
            pathType: Prefix
            backend:
              service:
                name: dash-service
                port:
                  number: 8050
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web-service
                port:
                  number: 80
```

---

## Phase 11: GitHub Actions Workflows

### `.github/workflows/infra-ci.yml`

```yaml
name: Infrastructure CI/CD (Terraform)

on:
  push:
    branches: [main]
    paths:
      - "infra/terraform/**"
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  deploy-dev:
    name: Terraform – dev
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - name: Azure Login (OIDC – no stored credentials)
        uses: azure/login@v2
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
    runs-on: ubuntu-latest
    environment: uat
    needs: [deploy-dev]
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
    runs-on: ubuntu-latest
    environment: prod
    needs: [deploy-uat]
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

### `.github/workflows/airflow-helm-deploy.yml`

```yaml
name: Airflow Helm Deploy

on:
  push:
    branches: [main]
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
    name: Helm Upgrade Airflow
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4

      - name: Azure Login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Get AKS Credentials
        run: |
          az aks get-credentials \
            --resource-group eq-tech-rg \
            --name eq-tech-aks \
            --overwrite-existing

      - name: Setup Helm
        uses: azure/setup-helm@v4

      - name: Add Airflow Helm Repo
        run: |
          helm repo add apache-airflow https://airflow.apache.org
          helm repo update

      - name: Helm Upgrade Airflow
        run: |
          helm upgrade --install airflow-dev apache-airflow/airflow \
            --namespace dev-airflow \
            --create-namespace \
            -f infra/helm/airflow-values.yaml \
            -f infra/helm/airflow-values/dev.yaml \
            --timeout 10m \
            --atomic

  deploy-uat:
    name: Helm Upgrade Airflow – uat
    runs-on: ubuntu-latest
    environment: uat
    needs: [deploy-dev]
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
      - name: Helm Upgrade Airflow
        run: |
          helm upgrade --install airflow-uat apache-airflow/airflow \
            --namespace uat-airflow \
            --create-namespace \
            -f infra/helm/airflow-values.yaml \
            -f infra/helm/airflow-values/uat.yaml \
            --timeout 10m \
            --atomic

  deploy-prod:
    name: Helm Upgrade Airflow – prod
    runs-on: ubuntu-latest
    environment: prod
    needs: [deploy-uat]
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
      - name: Helm Upgrade Airflow
        run: |
          helm upgrade --install airflow-prod apache-airflow/airflow \
            --namespace prod-airflow \
            --create-namespace \
            -f infra/helm/airflow-values.yaml \
            -f infra/helm/airflow-values/prod.yaml \
            --timeout 10m \
            --atomic
```

### `.github/workflows/apps-ci.yml`

```yaml
name: Apps CI/CD

on:
  push:
    branches: [main]
    paths:
      - "apps/**"
      - "k8s/**"
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
          # deployment/container fields map to the names used in k8s/apps/*.yaml
          - { name: api,     path: apps/api,     image: api,     deployment: api,      container: api      }
          - { name: ui-dash, path: apps/ui-dash,  image: ui-dash, deployment: dash-app, container: dash-app }
          - { name: ui-web,  path: apps/ui-web,   image: ui-web,  deployment: web-ui,   container: web-ui   }
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - name: Build & Push Docker Image to ACR
        run: |
          az acr build \
            --registry ${{ env.ACR_NAME }} \
            --image ${{ matrix.app.image }}:${{ github.sha }} \
            --image ${{ matrix.app.image }}:latest \
            --file ${{ matrix.app.path }}/Dockerfile \
            .   # repo root as context so lib/ is available inside the image

  deploy-dev:
    name: Deploy – dev
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
          kubectl set image deployment/${{ matrix.app.deployment }} \
            ${{ matrix.app.container }}=${{ env.ACR_LOGIN_SERVER }}/${{ matrix.app.image }}:${{ github.sha }} \
            -n dev-apps --ignore-not-found

  deploy-uat:
    name: Deploy – uat
    runs-on: ubuntu-latest
    environment: uat
    needs: [deploy-dev]
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
          kubectl set image deployment/${{ matrix.app.deployment }} \
            ${{ matrix.app.container }}=${{ env.ACR_LOGIN_SERVER }}/${{ matrix.app.image }}:${{ github.sha }} \
            -n uat-apps --ignore-not-found

  deploy-prod:
    name: Deploy – prod
    runs-on: ubuntu-latest
    environment: prod
    needs: [deploy-uat]
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
          kubectl set image deployment/${{ matrix.app.deployment }} \
            ${{ matrix.app.container }}=${{ env.ACR_LOGIN_SERVER }}/${{ matrix.app.image }}:${{ github.sha }} \
            -n prod-apps --ignore-not-found
```

> **DAG-only updates** (`data/airflow/dags/**`) do **not** trigger any workflow — git-sync polls the repo every 30 seconds and loads updated DAGs automatically. No container rebuild or Helm upgrade is required.

---

## Phase 12: Central Developer Workstation (Azure VM)

> **Note:** Azure Dev Box requires Microsoft Intune licensing (not included in the trial). An Azure VM is the equivalent alternative for this trial account. Multiple developers can SSH into this shared server; each gets their own OS user account but shares the same activated Python environment.

### 12.1 Create the VM

```bash
az vm create \
  --resource-group eq-tech-rg \
  --name eq-tech-devbox \
  --image Ubuntu2204 \
  --size Standard_B2ms \
  --admin-username devadmin \
  --generate-ssh-keys \
  --public-ip-sku Standard \
  --assign-identity                  # system-assigned identity for OS disk auto-expand

# Grant the VM identity Contributor on its own resource group so the
# quota auto-scale script can call az disk update without stored credentials
VM_PRINCIPAL=$(az vm show \
  --resource-group eq-tech-rg --name eq-tech-devbox \
  --query identity.principalId -o tsv)

az role assignment create \
  --role Contributor \
  --assignee "$VM_PRINCIPAL" \
  --scope /subscriptions/0702e805-0c66-4bbd-9eb4-47ce81ecb369/resourceGroups/eq-tech-rg

# Note the public IP for SSH access
az vm show --resource-group eq-tech-rg --name eq-tech-devbox \
  --show-details --query publicIps -o tsv
```

### 12.2 Install System Tools

```bash
DEVBOX_IP=$(az vm show --resource-group eq-tech-rg --name eq-tech-devbox \
  --show-details --query publicIps -o tsv)

ssh devadmin@$DEVBOX_IP bash -s << 'EOF'
  set -e
  apt-get update -qq
  apt-get install -y git curl unzip python3.11 python3.11-venv build-essential

  # Azure CLI
  curl -sL https://aka.ms/InstallAzureCLIDeb | bash

  # kubectl (direct download – reliable in non-interactive heredoc)
  curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

  # Helm
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

  # Terraform
  wget -qO /tmp/tf.zip https://releases.hashicorp.com/terraform/1.8.5/terraform_1.8.5_linux_amd64.zip
  unzip -o /tmp/tf.zip -d /usr/local/bin/

  # uv – fast Python package and venv manager
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ln -sf /root/.local/bin/uv /usr/local/bin/uv
EOF
```

### 12.3 Create the Shared Python Virtual Environment

All developers share a single read-only base venv at `/opt/eq-tech/venv`. It is built from `requirements/dev.txt` in the repo and managed by the platform admin. Developers activate it automatically on login.

```bash
ssh devadmin@$DEVBOX_IP bash -s << 'EOF'
  set -e

  # Clone the monorepo once as the system-level reference copy
  git clone https://github.com/ColumbiaDataScienceCorporation/eq_tech.git /opt/eq-tech/repo

  # Create the shared venv
  uv venv /opt/eq-tech/venv --python python3.11

  # Install all dev dependencies from requirements/dev.txt
  uv pip install \
    --python /opt/eq-tech/venv/bin/python \
    -r /opt/eq-tech/repo/requirements/dev.txt

  # Make the venv readable and activatable by all users, writable only by devadmin
  chown -R devadmin:devadmin /opt/eq-tech
  chmod -R 755 /opt/eq-tech/venv
EOF
```

### 12.4 Auto-Activate the Venv on Login

Create a profile script so every user who SSHs into the server automatically enters the shared Python environment:

```bash
ssh devadmin@$DEVBOX_IP sudo tee /etc/profile.d/eq-tech-env.sh << 'EOF'
#!/bin/bash
# Activate the shared EQ Tech Python development environment
if [ -f /opt/eq-tech/venv/bin/activate ]; then
    source /opt/eq-tech/venv/bin/activate
    export PYTHONPATH="/opt/eq-tech/repo:${PYTHONPATH}"
fi
EOF

ssh devadmin@$DEVBOX_IP sudo chmod +x /etc/profile.d/eq-tech-env.sh
```

Verify it works in a new session:

```bash
ssh devadmin@$DEVBOX_IP
# Shell prompt should show: (venv) devadmin@eq-tech-devbox:~$
python --version    # Python 3.11.x
python -c "import airflow; print(airflow.__version__)"  # 2.11.0
```

### 12.5 Per-Developer Disk Quota Enforcement with Auto-Scaling

Linux disk quotas set a **soft limit** (warning) and **hard limit** (enforced) per developer home directory. A cron script runs every 15 minutes, reads per-user usage from `repquota`, and automatically raises individual limits when a developer approaches their cap. When the OS disk itself runs low, the same script expands the Azure managed disk online using the VM's managed identity — no manual intervention required.

**Scale-up chain:**

```
Every 15 minutes:
  1. Check overall disk used%
     └── ≥ 80%: az disk update +64 GB → growpart → pvresize → lvextend → resize2fs
  2. For each developer (repquota -a):
     └── used ≥ 80% of hard limit:
          ├── hard < 50 GB ceiling: setquota raises soft +2 GB, hard +3 GB
          └── hard ≥ 50 GB ceiling: log warning, requires manual approval
```

#### Enable quotas on the dev server (run once as devadmin after VM creation)

```bash
ssh devadmin@$DEVBOX_IP bash -s << 'EOF'
  set -e
  apt-get install -y -q quota cloud-guest-utils

  # Ubuntu 22.04 Gen2 on Azure uses ext4 on LVM; enable usrquota on root
  if ! grep -q "usrquota" /etc/fstab; then
    sed -i '/[[:space:]]\//s/defaults/defaults,usrquota/' /etc/fstab
  fi
  mount -o remount /
  quotacheck -cum /
  quotaon /
  echo "Quota enforcement enabled:"
  quotaon -ap
EOF
```

#### Set initial quota for each developer (also done automatically in step 12.7)

```bash
# 5 GB soft = 5,242,880 KB | 8 GB hard = 8,388,608 KB
NEW_USER=alice
ssh devadmin@$DEVBOX_IP sudo setquota -u $NEW_USER 5242880 8388608 0 0 /
```

#### Deploy the auto-scale script

```bash
ssh devadmin@$DEVBOX_IP sudo tee /usr/local/bin/eq-tech-quota-autoscale.sh << 'SCRIPT'
#!/bin/bash
# Monitors per-developer quota usage and scales limits automatically.
# Also expands the OS disk (via managed identity) when the filesystem runs low.

set -uo pipefail

LOG=/var/log/eq-tech-quota-autoscale.log
SCALE_THRESHOLD=80         # % of hard limit that triggers a quota raise
SOFT_INCREMENT_KB=2097152  # +2 GB per scale event
HARD_INCREMENT_KB=3145728  # +3 GB per scale event
MAX_HARD_KB=52428800       # 50 GB ceiling; manual approval required beyond this
DISK_FULL_THRESHOLD=80     # % full that triggers OS disk expansion
OS_DISK_EXPAND_GB=64
RESOURCE_GROUP=eq-tech-rg
VM_NAME=eq-tech-devbox

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG"; }

# ── Expand the OS disk if the filesystem is nearing capacity ──────────────────
DISK_USED_PCT=$(df / --output=pcent | tail -1 | tr -d ' %')

if (( DISK_USED_PCT >= DISK_FULL_THRESHOLD )); then
    log "Disk ${DISK_USED_PCT}% full – expanding OS disk by ${OS_DISK_EXPAND_GB} GB"
    az login --identity --output none
    DISK_NAME=$(az vm show \
        --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" \
        --query "storageProfile.osDisk.name" -o tsv)
    CURRENT_GB=$(az disk show \
        --resource-group "$RESOURCE_GROUP" --name "$DISK_NAME" \
        --query "diskSizeGb" -o tsv)
    az disk update \
        --resource-group "$RESOURCE_GROUP" --name "$DISK_NAME" \
        --size-gb $(( CURRENT_GB + OS_DISK_EXPAND_GB ))
    sleep 30
    # Ubuntu 22.04 Gen2 LVM layout: partition 3 is the LVM PV
    growpart /dev/sda 3
    pvresize /dev/sda3
    lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
    resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
    log "OS disk expanded to $(( CURRENT_GB + OS_DISK_EXPAND_GB )) GB"
fi

# ── Per-developer quota auto-scale ───────────────────────────────────────────
# repquota -a field 2 is always a 2-char flag (e.g. --, -+, +-); use it to
# robustly skip header lines without depending on line-number counts.
repquota -a 2>/dev/null | while read -r username flag used_kb soft_kb hard_kb _rest; do
    [[ "$flag" =~ ^[-+]{2}$ ]] || continue
    uid=$(id -u "$username" 2>/dev/null) || continue
    (( uid < 1000 || hard_kb == 0 )) && continue

    used_pct=$(( used_kb * 100 / hard_kb ))

    if (( used_pct >= SCALE_THRESHOLD )); then
        if (( hard_kb >= MAX_HARD_KB )); then
            log "WARN: '$username' at ${used_pct}% (${used_kb}/${hard_kb} KB) – ceiling reached, manual review required"
            continue
        fi
        new_soft=$(( soft_kb + SOFT_INCREMENT_KB ))
        new_hard=$(( hard_kb + HARD_INCREMENT_KB ))
        setquota -u "$username" "$new_soft" "$new_hard" 0 0 /
        log "Scaled quota for '$username': ${used_pct}% → soft ${soft_kb}->${new_soft} KB, hard ${hard_kb}->${new_hard} KB"
    fi
done

log "Quota check complete (disk ${DISK_USED_PCT}% used)"
SCRIPT

ssh devadmin@$DEVBOX_IP sudo chmod +x /usr/local/bin/eq-tech-quota-autoscale.sh
```

#### Schedule auto-scale every 15 minutes

```bash
ssh devadmin@$DEVBOX_IP sudo tee /etc/cron.d/eq-tech-quota-autoscale << 'CRON'
*/15 * * * * root /usr/local/bin/eq-tech-quota-autoscale.sh
CRON
```

#### Check quota usage and scale history

```bash
# Live per-user usage report
ssh devadmin@$DEVBOX_IP sudo repquota -as /

# Auto-scale event history
ssh devadmin@$DEVBOX_IP sudo tail -50 /var/log/eq-tech-quota-autoscale.log
```

---

### 12.6 Configure kubectl and Azure CLI on the Dev Server

Run these once after Terraform has created the AKS cluster:

```bash
ssh devadmin@$DEVBOX_IP bash -s << 'EOF'
  # Login to Azure (opens browser link – follow the instructions)
  az login
  az account set --subscription 0702e805-0c66-4bbd-9eb4-47ce81ecb369

  # Pull AKS kubeconfig into ~/.kube/config
  az aks get-credentials \
    --resource-group eq-tech-rg \
    --name eq-tech-aks \
    --overwrite-existing

  kubectl get nodes  # confirm connectivity
EOF
```

### 12.7 Developer Onboarding (Per-Developer Steps)

For each new developer who needs access to the central dev server:

```bash
# 1. Create their OS user and apply disk quota (run as devadmin)
DEVBOX_IP=<DEVBOX_PUBLIC_IP>
NEW_USER=alice

ssh devadmin@$DEVBOX_IP bash -s << EOF
  useradd -m -s /bin/bash $NEW_USER
  # Add their SSH public key
  mkdir -p /home/$NEW_USER/.ssh
  echo "<DEVELOPER_SSH_PUBLIC_KEY>" >> /home/$NEW_USER/.ssh/authorized_keys
  chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh
  chmod 700 /home/$NEW_USER/.ssh
  chmod 600 /home/$NEW_USER/.ssh/authorized_keys
  # Apply disk quota: 5 GB soft, 8 GB hard
  setquota -u $NEW_USER 5242880 8388608 0 0 /
EOF

# 2. When the developer logs in for the first time, they clone their own working copy
# (The shared venv in /opt/eq-tech/venv is activated automatically via /etc/profile.d/)
ssh alice@$DEVBOX_IP << 'EOF'
  git clone https://github.com/ColumbiaDataScienceCorporation/eq_tech.git ~/eq_tech
  cd ~/eq_tech
  git config user.email "alice@example.com"
  git config user.name "Alice"
  # Configure a GitHub PAT for push access
  git remote set-url origin https://<GITHUB_PAT>@github.com/ColumbiaDataScienceCorporation/eq_tech.git
EOF
```

### 12.8 Keeping the Shared Venv Up to Date

When `requirements/dev.txt` changes in the repo, run this on the dev server as `devadmin` to update the shared venv:

```bash
ssh devadmin@$DEVBOX_IP bash -s << 'EOF'
  cd /opt/eq-tech/repo
  git pull
  uv pip install \
    --python /opt/eq-tech/venv/bin/python \
    -r requirements/dev.txt
EOF
```

Optionally add this as a nightly cron job:

```bash
ssh devadmin@$DEVBOX_IP sudo tee /etc/cron.d/eq-tech-venv-sync << 'EOF'
0 2 * * * devadmin cd /opt/eq-tech/repo && git pull && uv pip install --python /opt/eq-tech/venv/bin/python -r requirements/dev.txt >> /var/log/eq-tech-venv-sync.log 2>&1
EOF
```

### 12.9 Create the `.env` File (Step 6c)

Now that the dev server exists and Step 7 has provisioned PostgreSQL, create the `.env` file in your working copy on the server. Do **not** commit it — it is already in `.gitignore`.

```bash
DEVBOX_IP=<DEVBOX_PUBLIC_IP>
PG_FQDN=$(terraform -chdir=c:\eq_tech\infra\terraform output -raw postgres_fqdn)

ssh devadmin@$DEVBOX_IP bash -s << EOF
cat > ~/eq_tech/.env << ENVFILE
EQTECH_ENVIRONMENT=dev

# Entra ID group Object IDs (from Step 6b)
EQTECH_ANALYSTS_GROUP_ID=e5027eb5-1610-4b88-b68e-8b59af3e3052
EQTECH_PORTFOLIO_MANAGERS_GROUP_ID=c6a15f1b-fe3e-4419-b43e-a740a9366b1f
EQTECH_RISK_GROUP_ID=e9d1a418-656c-4721-96e7-be308c809e44
EQTECH_ADMINS_GROUP_ID=4d39f097-51ec-46c5-a2ac-9f49b86eb28d

# PostgreSQL
EQTECH_POSTGRES_HOST=$PG_FQDN
EQTECH_POSTGRES_USER=airflow_admin
EQTECH_POSTGRES_PASSWORD=<pg_admin_password>
ENVFILE
EOF
```

`lib/config/settings.py` picks this file up automatically via `pydantic-settings` when running code on the dev server.

---

## Manual Prerequisites Checklist

Execute these steps **in order**. Each step unlocks the next.

> **Steps 2, 3, and 4 are automated.** Run `scripts/bootstrap.ps1` from the repo root to complete them in one shot:
>
> ```powershell
> cd c:\eq_tech
> .\scripts\bootstrap.ps1
> ```
>
> The script is idempotent — safe to re-run. It prints all GitHub Secrets values at the end.

```
Step 1  Push scaffold to GitHub (placeholders still in files)
Step 2  Bootstrap Terraform state backend                        ← scripts/bootstrap.ps1
Step 3  Create OIDC service principal → add GitHub Secrets       ← scripts/bootstrap.ps1
Step 4  Create Entra ID App Registration → add GitHub Secrets    ← scripts/bootstrap.ps1
Step 5  Create GitHub Environments (dev / uat / prod)
Step 6  Set Entra ID Group Object IDs
Step 7  Terraform apply (dev) -> install NGINX Ingress -> get LB_IP    <- scripts/provision-dev.ps1
        + 7e: create eq-tech-groups ConfigMap in all app namespaces      <- scripts/provision-dev.ps1
Step 8  Replace <LB_IP> everywhere → commit → push           ← runs CI/CD for first time
Step 9  Update Entra ID redirect URIs with real URLs
Step 10 Create Kubernetes secrets (per environment)
Step 11 Deploy OAuth2 Proxy and Airflow (first time, manually)
Step 12 Change default Airflow admin password
```

---

### Step 1 — Push the scaffold to GitHub Enterprise `[no Phase — git only]`

The initial push goes up **with `<LB_IP>` placeholders still in the files**. You will replace them in Step 8 once the IP exists.

```bash
cd c:\eq_tech
git init
git remote add origin https://github.com/ColumbiaDataScienceCorporation/eq_tech.git
git add .
git commit -m "chore: initial platform scaffold"
git push -u origin main
```

---

### Step 2 — Bootstrap Terraform State Backend `[Phase 2]` *(automated in `scripts/bootstrap.ps1`)*

> **Run `scripts/bootstrap.ps1` instead.** The manual commands below are for reference only.

```bash
az login
az account set --subscription 0702e805-0c66-4bbd-9eb4-47ce81ecb369

az group create --name eq-tech-tfstate-rg --location eastus

az storage account create --name eqtechtfstate \
  --resource-group eq-tech-tfstate-rg --location eastus --sku Standard_LRS

az storage container create --name tfstate --account-name eqtechtfstate
```

---

### Step 3 — Create the OIDC Service Principal `[Phase 3]` *(automated in `scripts/bootstrap.ps1`)*

> **Run `scripts/bootstrap.ps1` first.** It creates the app registration, service principal, role assignment, and OIDC federated credentials automatically.
>
> After the script finishes, do the following three manual actions:

#### 3a — Create the `GIT_SYNC_TOKEN` Fine-Grained PAT

Navigate to `https://github.com/settings/tokens?type=beta` and create a new token:

| Field             | Value                                          |
| ----------------- | ---------------------------------------------- |
| Token name        | `eq-tech-git-sync`                           |
| Expiration        | 1 year                                         |
| Repository access | Only`ColumbiaDataScienceCorporation/eq_tech` |
| Permission        | **Contents → Read-only**                |

Copy the token value — it is shown only once.

#### 3b — Add GitHub Actions Secrets

Navigate to `https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings/secrets/actions` and add all seven secrets:

| Secret name               | Where to get the value                                                    |
| ------------------------- | ------------------------------------------------------------------------- |
| `AZURE_CLIENT_ID`       | Printed by`bootstrap.ps1`                                               |
| `AZURE_TENANT_ID`       | `e5e33b11-e89c-466a-bf06-e94151676845` (fixed)                          |
| `AZURE_SUBSCRIPTION_ID` | `0702e805-0c66-4bbd-9eb4-47ce81ecb369` (fixed)                          |
| `OAUTH2_CLIENT_ID`      | Printed by`bootstrap.ps1`                                               |
| `OAUTH2_CLIENT_SECRET`  | Printed by`bootstrap.ps1` (shown once — save immediately)              |
| `PG_ADMIN_PASSWORD`     | Choose a strong password ≥16 chars — you will use this again in Step 10 |
| `GIT_SYNC_TOKEN`        | The Fine-Grained PAT created in step 3a above                             |

---

### Step 4 — Create Entra ID App Registration for OAuth2 Proxy `[Phase 4]` *(automated in `scripts/bootstrap.ps1`)*

> The app registration, groups claim, Graph permissions, admin consent, and client secret are all created by `scripts/bootstrap.ps1`.
> The secret value is printed at the end of the script run — add it to GitHub Secrets as `OAUTH2_CLIENT_SECRET` (covered in Step 3b above).

---

### Step 5 — Create GitHub Environments with Protection Rules `[no Phase — GitHub UI only]`

Navigate to `https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings/environments` and create three environments:

| Environment | Required reviewers          | Wait timer | Deployment branches |
| ----------- | --------------------------- | ---------- | ------------------- |
| `dev`     | None                        | None       | `main` only       |
| `uat`     | Add yourself (or team lead) | None       | `main` only       |
| `prod`    | Add ≥2 reviewers           | 10 minutes | `main` only       |

For each environment, under **Deployment branches**, choose **Selected branches** and add the pattern `main`.

---

### Step 6 — Set Entra ID Group Object IDs `[no Phase — Azure Portal + Phase 12.9 for .env]`

> **When to do this:** You can create the groups and note their Object IDs right now (before infrastructure exists). The `.env` file and `kubectl create configmap` commands at the end of this step must wait until after Step 7 (AKS cluster exists).

#### 6a — Create the Security Groups in Entra ID

Navigate to **Azure Portal → Entra ID → Groups → + New group** and fill in the form once for each group below:

| Field                                    | Value                                         |
| ---------------------------------------- | --------------------------------------------- |
| **Group type**                     | Security                                      |
| **Group name**                     | e.g.`eq-tech-analysts`                      |
| **Group description**              | e.g.`EQ Tech platform – analytics viewers` |
| **Azure AD roles can be assigned** | No                                            |
| **Membership type**                | Assigned                                      |
| **Owners**                         | Add yourself                                  |
| **Members**                        | Add team members who should have this role    |

Repeat for each of the four groups:

| Group name (suggestion)        | Used for                                                      |
| ------------------------------ | ------------------------------------------------------------- |
| `eq-tech-analysts`           | Read-only analytics access (Dash app, API portfolio endpoint) |
| `eq-tech-portfolio-managers` | Portfolio management access                                   |
| `eq-tech-risk`               | Risk dashboard access                                         |
| `eq-tech-admins`             | Full platform admin access (includes Airflow UI)              |

> **Note:** Group names are arbitrary — use whatever naming convention your organisation prefers. The code only checks the Object ID (a UUID), not the name.

#### 6b — Find each group's Object ID

After creating each group:

1. Go to **Azure Portal → Entra ID → Groups**
2. Click the group name
3. On the **Overview** page, copy the **Object ID** field (format: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)

Keep these four UUIDs — you'll need them in Steps 12.9 and 7e.

> **When:** 6a and 6b can be done now (no infrastructure needed). The `.env` file on the dev server is Step 12.9 — after the VM exists.

---

### Step 7 — Provision Infrastructure and Get the LoadBalancer IP `[Phase 2 + Phase 5]` *(automated in `scripts/provision-dev.ps1`)*

> **Run `scripts/provision-dev.ps1` instead of the manual commands below.** It handles sub-steps 7a–7e. Pass your group Object IDs as parameters so 7e runs automatically:
> ```powershell
> .\scripts\provision-dev.ps1 `
>     -AnalystsGroupId          e5027eb5-1610-4b88-b68e-8b59af3e3052 `
>     -PortfolioManagersGroupId c6a15f1b-fe3e-4419-b43e-a740a9366b1f `
>     -RiskGroupId              e9d1a418-656c-4721-96e7-be308c809e44 `
>     -AdminsGroupId            4d39f097-51ec-46c5-a2ac-9f49b86eb28d
> ```
> If group IDs are omitted, the script prompts for them interactively.
>
> ```powershell
> .\scripts\provision-dev.ps1
> ```

This step creates the AKS cluster, installs NGINX Ingress, and captures the public IP that all subsequent steps depend on.

#### 7a — Terraform apply (dev workspace)

```bash
cd infra/terraform
terraform init

terraform workspace new dev
terraform workspace new uat
terraform workspace new prod

terraform workspace select dev
terraform apply \
  -var-file environments/dev.tfvars \
  -var "postgres_admin_password=<PG_ADMIN_PASSWORD>"
```

#### 7b — Get AKS credentials and install NGINX Ingress

```bash
az aks get-credentials --resource-group eq-tech-rg --name eq-tech-aks

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=1
```

#### 7c — Wait for the LoadBalancer IP (takes 1–3 minutes)

```bash
# Watch until EXTERNAL-IP is no longer <pending>
kubectl get svc -n ingress-nginx ingress-nginx-controller --watch

# Capture the IP
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  --output jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Example output: `20.1.2.3` — note this value, you will use it in Step 8.

#### 7d — Create Kubernetes namespaces

```bash
kubectl apply -f k8s/namespaces.yaml
```

#### 7e — Create Kubernetes ConfigMap for Entra ID Group IDs

The API and Dash pods read group IDs from the `eq-tech-groups` ConfigMap (already referenced via `envFrom` in `k8s/apps/api-deployment.yaml` and `k8s/apps/dash-deployment.yaml`). Substitute your actual Object IDs from Step 6b:

```bash
for NS in dev-apps uat-apps prod-apps; do
  kubectl create configmap eq-tech-groups --namespace $NS \
    --from-literal=EQTECH_ANALYSTS_GROUP_ID=<uuid> \
    --from-literal=EQTECH_PORTFOLIO_MANAGERS_GROUP_ID=<uuid> \
    --from-literal=EQTECH_RISK_GROUP_ID=<uuid> \
    --from-literal=EQTECH_ADMINS_GROUP_ID=<uuid>
done

# Verify
kubectl get configmap eq-tech-groups -n dev-apps -o yaml
```

---

### Step 8 — Replace `<LB_IP>` Everywhere and Push `[Phase 6, 7, 7b, k8s/ingress]`

#### What is `<LB_IP>` and why is it needed?

Every ingress hostname, OAuth2 redirect URI, and Airflow base URL is built around the **NGINX Ingress LoadBalancer IP**. The plan uses `nip.io`, a free public DNS service: any subdomain of an IP address automatically resolves back to that IP with no DNS registration needed.

| Subdomain                       | Resolves to  | Environment |
| ------------------------------- | ------------ | ----------- |
| `dev.eq-tech.20.1.2.3.nip.io` | `20.1.2.3` | Dev         |
| `uat.eq-tech.20.1.2.3.nip.io` | `20.1.2.3` | UAT         |
| `eq-tech.20.1.2.3.nip.io`     | `20.1.2.3` | Prod        |

All three subdomains hit the same NGINX controller; it routes each request to the right namespace via the Ingress `host:` rule.

#### Replace in your local clone

```powershell
cd c:\eq_tech
git pull

$LB_IP = "20.1.2.3"   # ← your actual IP from Step 7c

Get-ChildItem -Recurse -File . |
  Where-Object { $_.Extension -in '.yaml', '.yml', '.tf', '.tfvars' } |
  ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    if ($content -match '<LB_IP>') {
      ($content -replace '<LB_IP>', $LB_IP) | Set-Content $_.FullName -NoNewline
      Write-Host "Updated: $($_.FullName)"
    }
  }

# Verify – should return no output if all replaced
Select-String -Recurse -Path . -Pattern '<LB_IP>' -Include '*.yaml','*.yml','*.tf'
```

The following 11 files will be updated:

| File                                         | What it controls                         |
| -------------------------------------------- | ---------------------------------------- |
| `infra/helm/airflow-values.yaml`           | Base Airflow`base_url`                 |
| `infra/helm/airflow-values/dev.yaml`       | Dev Airflow URL + ingress host           |
| `infra/helm/airflow-values/uat.yaml`       | UAT Airflow URL + ingress host           |
| `infra/helm/airflow-values/prod.yaml`      | Prod Airflow URL + ingress host          |
| `infra/helm/oauth2-proxy-values.yaml`      | Base OAuth2 redirect URL                 |
| `infra/helm/oauth2-proxy-values/dev.yaml`  | Dev OAuth2 callback + ingress host       |
| `infra/helm/oauth2-proxy-values/uat.yaml`  | UAT OAuth2 callback + ingress host       |
| `infra/helm/oauth2-proxy-values/prod.yaml` | Prod OAuth2 callback + ingress host      |
| `k8s/ingress/dev.yaml`                     | Dev HTTP routing + auth-signin redirect  |
| `k8s/ingress/uat.yaml`                     | UAT HTTP routing + auth-signin redirect  |
| `k8s/ingress/prod.yaml`                    | Prod HTTP routing + auth-signin redirect |

#### Commit and push — this triggers CI/CD for the first time

```powershell
git add infra/helm/ k8s/ingress/
git commit -m "chore: resolve LB_IP placeholders (<your_ip>)"
git push origin main
```

GitHub Actions will run `apps-ci.yml` automatically. The `dev` jobs build images and deploy app pods to `dev-apps`. They will succeed. OAuth2 Proxy and Airflow are not yet deployed so the UI won't authenticate yet — that happens in Step 11.

> **For production with a real domain:** replace all `nip.io` URLs with your actual domain (e.g., `dev.yourdomain.com`, `yourdomain.com`), create Azure DNS A records pointing to the LB IP, and use those domains in the Entra ID registration too.

---

### Step 9 — Update Entra ID Redirect URIs `[Phase 4.4]`

Now that the real URLs are known, update the Entra ID App Registration (Phase 4.4):

```bash
az ad app update \
  --id $OAUTH_APP_ID \
  --web-redirect-uris \
    "https://dev.eq-tech.<LB_IP>.nip.io/oauth2/callback" \
    "https://uat.eq-tech.<LB_IP>.nip.io/oauth2/callback" \
    "https://eq-tech.<LB_IP>.nip.io/oauth2/callback"
```

---

### Step 10 — Create Kubernetes Secrets `[Phase 5.4]`

```bash
PG_FQDN=$(terraform -chdir=infra/terraform output -raw postgres_fqdn)

for ENV in dev uat prod; do
  kubectl create secret generic airflow-postgres-secret --namespace ${ENV}-airflow \
    --from-literal=connection="postgresql+psycopg2://airflow_admin:<PG_PASSWORD>@${PG_FQDN}/airflow_${ENV}?sslmode=require"
  kubectl create secret generic github-git-sync-token --namespace ${ENV}-airflow \
    --from-literal=GIT_SYNC_USERNAME=x-access-token \
    --from-literal=GIT_SYNC_PASSWORD=<GIT_SYNC_TOKEN> \
    --from-literal=GITSYNC_USERNAME=x-access-token \
    --from-literal=GITSYNC_PASSWORD=<GIT_SYNC_TOKEN>
done

COOKIE=$(python3 -c "import secrets,base64;print(base64.b64encode(secrets.token_bytes(16)).decode())")
kubectl create secret generic oauth2-proxy-secret --namespace auth \
  --from-literal=client-id=<OAUTH2_CLIENT_ID> \
  --from-literal=client-secret=<OAUTH2_CLIENT_SECRET> \
  --from-literal=cookie-secret=$COOKIE
```

---

### Step 11 — Deploy OAuth2 Proxy and Airflow (First Time) `[Phase 6 + Phase 7]`

Subsequent updates are handled by `airflow-helm-deploy.yml`. This is only needed once to bootstrap.

```bash
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests && helm repo update
helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy \
  --namespace auth \
  -f infra/helm/oauth2-proxy-values.yaml \
  -f infra/helm/oauth2-proxy-values/dev.yaml

helm repo add apache-airflow https://airflow.apache.org && helm repo update
helm upgrade --install airflow-dev apache-airflow/airflow \
  --namespace dev-airflow \
  -f infra/helm/airflow-values.yaml \
  -f infra/helm/airflow-values/dev.yaml \
  --timeout 10m --atomic
```

---

### Step 12 — Change the Default Airflow Admin Password `[Phase 7 — Airflow UI]`

Log in to the Airflow UI at `https://dev.eq-tech.<LB_IP>.nip.io/airflow/` and immediately change the password from the default `ChangeMe123!`. In production, disable `defaultUser` in `airflow-values.yaml` and use Entra ID SSO as the Airflow auth backend instead.

---

## Phase 13: End-to-End Deployment Order

**Before starting the numbered sequence, complete these manual steps in order:**

|   | Phase            | What to do                                                                                                                                      |
| - | ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| A | Phase 12.1–12.4 | Create the dev server VM, install tools, create shared venv                                                                                     |
| B | Phase 3          | Create the OIDC service principal; add`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` secrets to GitHub                     |
| C | Phase 4.1–4.3   | Create the Entra ID app registration (placeholder redirect URI for now); add`OAUTH2_CLIENT_ID` and `OAUTH2_CLIENT_SECRET` secrets to GitHub |

Then execute the numbered steps in sequence:

```bash
# ── Step 1: Bootstrap Terraform state backend (once) ──────────────────────
az group create --name eq-tech-tfstate-rg --location eastus
az storage account create --name eqtechtfstate --resource-group eq-tech-tfstate-rg \
  --location eastus --sku Standard_LRS
az storage container create --name tfstate --account-name eqtechtfstate

# ── Step 2: Provision infrastructure via Terraform ────────────────────────
cd infra/terraform
terraform init
terraform workspace select dev || terraform workspace new dev
terraform apply \
  -var-file environments/dev.tfvars \
  -var "postgres_admin_password=<YOUR_STRONG_PASSWORD>"
cd ../..

# ── Step 2b: Complete Phase 12.5–12.8 now (quota setup, kubectl config, ─────
#            developer onboarding) – the AKS cluster name is now known.

# ── Step 3: Connect kubectl to AKS ───────────────────────────────────────
az aks get-credentials --resource-group eq-tech-rg --name eq-tech-aks

# ── Step 4: Create Kubernetes namespaces ─────────────────────────────────
kubectl apply -f k8s/namespaces.yaml

# ── Step 5: Install NGINX Ingress Controller ─────────────────────────────
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace

# ── Step 6: Get the LoadBalancer IP ──────────────────────────────────────
kubectl get svc -n ingress-nginx ingress-nginx-controller
# Note <LB_IP> from EXTERNAL-IP and update all placeholder values in:
#   infra/helm/oauth2-proxy-values.yaml
#   infra/helm/airflow-values.yaml
#   k8s/ingress/{dev,uat,prod}.yaml
#   Entra ID App Registration redirect URI (Phase 4.4)

# ── Step 7: Create Kubernetes secrets ────────────────────────────────────
PG_FQDN=$(terraform -chdir=infra/terraform output -raw postgres_fqdn)
COOKIE_SECRET=$(python3 -c "import secrets,base64; print(base64.b64encode(secrets.token_bytes(16)).decode())")

kubectl create secret generic airflow-postgres-secret --namespace airflow \
  --from-literal=connection="postgresql+psycopg2://airflow_admin:<PG_PASSWORD>@${PG_FQDN}/airflow"

kubectl create secret generic github-git-sync-token --namespace airflow \
  --from-literal=GIT_SYNC_USERNAME=x-access-token \
  --from-literal=GIT_SYNC_PASSWORD=<GITHUB_FINE_GRAINED_PAT>

kubectl create secret generic oauth2-proxy-secret --namespace auth \
  --from-literal=client-id=<OAUTH2_CLIENT_ID> \
  --from-literal=client-secret=<OAUTH2_CLIENT_SECRET> \
  --from-literal=cookie-secret=$COOKIE_SECRET

# ── Step 8: Deploy OAuth2 Proxy ───────────────────────────────────────────
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests && helm repo update
helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy \
  --namespace auth -f infra/helm/oauth2-proxy-values.yaml \
  -f infra/helm/oauth2-proxy-values/dev.yaml

# ── Step 9: Deploy Airflow ────────────────────────────────────────────────
helm repo add apache-airflow https://airflow.apache.org && helm repo update
helm upgrade --install airflow apache-airflow/airflow \
  --namespace airflow -f infra/helm/airflow-values.yaml --timeout 10m --atomic

# ── Step 10: Build and push application images ───────────────────────────
# Build context is the REPO ROOT (.) so lib/ is available inside each image
az acr build --registry eqtechacr --image api:latest     --file apps/api/Dockerfile     .
az acr build --registry eqtechacr --image ui-dash:latest --file apps/ui-dash/Dockerfile .
az acr build --registry eqtechacr --image ui-web:latest  --file apps/ui-web/Dockerfile  .

# ── Step 11: Deploy app manifests and ingress (dev; uat/prod via GitHub Actions) ─
kubectl apply -f k8s/apps/ -n dev-apps
kubectl apply -f k8s/ingress/dev.yaml -n dev-apps

# ── Step 12: Verify everything is running ────────────────────────────────
kubectl get pods -n dev-airflow
kubectl get pods -n dev-apps
kubectl get pods -n auth
kubectl get ingress -n dev-apps
```

---

## Phase 14: Verification Checklist

| Test                            | Command / URL                                                                                      |
| ------------------------------- | -------------------------------------------------------------------------------------------------- |
| AKS nodes ready                 | `kubectl get nodes`                                                                              |
| Airflow pods running            | `kubectl get pods -n dev-airflow`                                                                |
| git-sync pulling DAGs           | `kubectl logs -n dev-airflow -l component=scheduler -c git-sync`                                 |
| Airflow UI (dev)                | `https://dev.eq-tech.<LB_IP>.nip.io/airflow/` (redirects to Entra ID login)                      |
| OAuth2 Proxy redirect           | Browse`https://dev.eq-tech.<LB_IP>.nip.io/` → should redirect to Microsoft login                |
| API health (unauthenticated)    | `curl https://dev.eq-tech.<LB_IP>.nip.io/api/healthz` → `{"status":"healthy"}`                |
| API me endpoint (authenticated) | Browse`/api/v1/me` after login → returns user, email, groups                                    |
| Dash app (dev)                  | `https://dev.eq-tech.<LB_IP>.nip.io/dash/`                                                       |
| Web UI (dev)                    | `https://dev.eq-tech.<LB_IP>.nip.io/`                                                            |
| Hello World DAG                 | Trigger manually in Airflow UI → both tasks succeed                                               |
| Daily ETL DAG                   | Trigger manually → extract, transform, load tasks succeed                                         |
| GitHub Actions OIDC             | Push to`main` → Actions tab shows dev, then (after approval) uat, then prod                     |
| uat deployment                  | Approve`uat` GitHub Environment → jobs run, `kubectl get pods -n uat-airflow` shows Running   |
| prod deployment                 | Approve`prod` GitHub Environment → jobs run, `kubectl get pods -n prod-airflow` shows Running |

---

## Cost Estimate (Azure Trial)

| Resource                       | SKU                           | Est. Monthly          |
| ------------------------------ | ----------------------------- | --------------------- |
| AKS – 2× Standard_B4ms nodes | B4ms (4 vCPU / 16 GB)         | ~$140                 |
| PostgreSQL Flexible Server     | B_Standard_B1ms               | ~$15                  |
| Azure Container Registry       | Basic                         | ~$5                   |
| Azure Key Vault                | Standard                      | ~$1                   |
| Developer VM                   | Standard_B2ms (2 vCPU / 8 GB) | ~$35                  |
| **Total**                |                               | **~$196/month** |

> The Azure trial provides **$200 USD credit (30 days)**. To reduce cost, scale the AKS node pool to `Standard_B2s` (2 vCPU / 4 GB, ~$35/node) and delete the developer VM when not in use.

---

## Security Notes

1. **No secrets in the repo.** All credentials are stored in GitHub Actions Secrets and Kubernetes Secrets only.
2. **OIDC federation** means GitHub Actions never holds a long-lived Azure credential. Tokens expire when the job ends.
3. **PostgreSQL firewall** is open to all IPs in this plan for trial convenience. In production, restrict to the AKS egress public IP.
4. **git-sync PAT** must be a [GitHub Fine-Grained Token](https://github.com/settings/tokens?type=beta) with read-only `Contents` permission scoped to the `eq_tech` repository only.
5. **OAuth2 Proxy cookie secret** must be random (generated with `secrets.token_bytes`) and stored only in the Kubernetes Secret — never committed to the repo.
6. **Group overflow:** If the Entra ID account ever belongs to >150 groups, the groups claim will be omitted from the OIDC token. For the trial account this is not a concern.
