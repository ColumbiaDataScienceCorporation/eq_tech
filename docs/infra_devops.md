# EQ Tech – Infrastructure DevOps Runbook

## 1. Infrastructure Overview

The EQ Tech platform runs on a **single shared AKS cluster** with environment isolation via Kubernetes namespaces. Terraform workspaces maintain separate state files per environment while reusing the same `main.tf`. This architecture is cost-effective for the trial and can be migrated to separate clusters per environment later without code changes.

```
Azure Subscription: 0702e805-0c66-4bbd-9eb4-47ce81ecb369
└── Resource Group: eq-tech-rg
    ├── AKS Cluster: eq-tech-aks (shared)
    │   ├── Namespace: auth           (shared OAuth2 Proxy)
    │   ├── Namespace: dev-airflow    ┐
    │   ├── Namespace: dev-apps       ├── dev environment
    │   ├── Namespace: uat-airflow    ┤
    │   ├── Namespace: uat-apps       ├── uat environment
    │   ├── Namespace: prod-airflow   ┤
    │   └── Namespace: prod-apps      └── prod environment
    ├── PostgreSQL Flexible Server: eq-tech-pg
    │   ├── Database: airflow_dev
    │   ├── Database: airflow_uat
    │   └── Database: airflow_prod
    ├── Azure Container Registry: eqtechacr
    ├── Azure Key Vault: eq-tech-kv
    └── Dev Server VM: eq-tech-devbox

Terraform State (separate storage account)
└── Resource Group: eq-tech-tfstate-rg
    └── Storage Account: eqtechtfstate
        └── Container: tfstate
            ├── env:/dev/eq-tech.tfstate
            ├── env:/uat/eq-tech.tfstate
            └── env:/prod/eq-tech.tfstate
```

---

## 2. Do You Need to Initialize All Three Environments at Once?

**No.** Use a phased rollout. Spinning up UAT and prod before you have stable software wastes trial credit and adds operational noise.

### Recommended Initialization Sequence

| Phase | When | What gets created |
|---|---|---|
| **A** (Day 1) | Before any development | Central dev server VM + shared venv |
| **B** (Day 1–2) | Once, shared across all envs | AKS cluster, ACR, PostgreSQL server, Key Vault, Terraform state backend |
| **C** (Day 1–2) | Immediately after B | `dev` workspace: `airflow_dev` database, `dev-airflow`/`dev-apps` namespaces, Helm deploys |
| **D** (When first feature is ready for QA) | After dev is stable | `uat` workspace: `airflow_uat` database, `uat-*` namespaces, Helm deploys |
| **E** (When UAT is validated) | Before going live | `prod` workspace: `airflow_prod` database, `prod-*` namespaces, Helm deploys |

The AKS cluster, ACR, PostgreSQL **server**, and Key Vault are provisioned once (Phase B) and shared. Only **databases** and **Kubernetes namespaces** are created per environment.

---

## 3. Phase A: Central Dev Server Initialization

The dev server must exist before running any of the subsequent phases because it is the machine from which all infrastructure commands are executed.

### 3.1 Create the VM

```bash
# Run from your local Windows workstation
az login
az account set --subscription 0702e805-0c66-4bbd-9eb4-47ce81ecb369

az vm create \
  --resource-group eq-tech-rg \
  --name eq-tech-devbox \
  --image Ubuntu2204 \
  --size Standard_B2ms \
  --admin-username devadmin \
  --generate-ssh-keys \
  --public-ip-sku Standard \
  --assign-identity

# Grant the VM's managed identity Contributor on the resource group
# (needed by the disk quota auto-scale script)
VM_PRINCIPAL=$(az vm show \
  --resource-group eq-tech-rg --name eq-tech-devbox \
  --query identity.principalId -o tsv)

az role assignment create \
  --role Contributor \
  --assignee "$VM_PRINCIPAL" \
  --scope /subscriptions/0702e805-0c66-4bbd-9eb4-47ce81ecb369/resourceGroups/eq-tech-rg

# Hard stop every day at 21:00 UTC (5 PM ET) in case the idle script misses
az vm auto-shutdown \
  --resource-group eq-tech-rg --name eq-tech-devbox \
  --time 2100

DEVBOX_IP=$(az vm show --resource-group eq-tech-rg --name eq-tech-devbox \
  --show-details --query publicIps -o tsv)
```

### 3.1b Idle Auto-Deallocate

Install a cron job that deallocates the VM after 30 consecutive idle minutes (no SSH sessions + load average < 0.10). Requires §3.2 (az CLI) to be installed first.

```bash
ssh devadmin@$DEVBOX_IP sudo tee /usr/local/bin/eq-tech-idle-shutdown.sh << 'SCRIPT'
#!/bin/bash
# Deallocates the VM after IDLE_MINUTES of inactivity.
IDLE_MINUTES=30
STATE=/var/run/eq-tech-idle-count

[ "$(who | wc -l)" -gt 0 ] && { echo 0 > "$STATE"; exit 0; }

LOAD=$(awk '{printf "%d", $1 * 100}' /proc/loadavg)
COUNT=$(cat "$STATE" 2>/dev/null || echo 0)

if [ "$LOAD" -lt 10 ]; then COUNT=$((COUNT + 1)); else COUNT=0; fi
echo "$COUNT" > "$STATE"

if [ "$COUNT" -ge "$IDLE_MINUTES" ]; then
    echo 0 > "$STATE"
    logger -t eq-tech-idle-shutdown "Idle ${IDLE_MINUTES} min – deallocating"
    RESOURCE_ID=$(curl -sf -H "Metadata:true" \
        "http://169.254.169.254/metadata/instance?api-version=2021-02-01" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['compute']['resourceId'])")
    az login --identity --output none
    az vm deallocate --ids "$RESOURCE_ID" --no-wait
fi
SCRIPT

ssh devadmin@$DEVBOX_IP sudo chmod +x /usr/local/bin/eq-tech-idle-shutdown.sh
ssh devadmin@$DEVBOX_IP sudo tee /etc/cron.d/eq-tech-idle-shutdown << 'CRON'
* * * * * root /usr/local/bin/eq-tech-idle-shutdown.sh
CRON
```

### 3.2 Install Tools

```bash
ssh devadmin@$DEVBOX_IP bash -s << 'EOF'
  set -e
  apt-get update -qq
  apt-get install -y git curl unzip python3.11 python3.11-venv build-essential \
                     quota cloud-guest-utils

  # Azure CLI
  curl -sL https://aka.ms/InstallAzureCLIDeb | bash

  # kubectl
  curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

  # Helm
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

  # Terraform
  wget -qO /tmp/tf.zip https://releases.hashicorp.com/terraform/1.8.5/terraform_1.8.5_linux_amd64.zip
  unzip -o /tmp/tf.zip -d /usr/local/bin/

  # uv (fast Python package and venv manager)
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ln -sf /root/.local/bin/uv /usr/local/bin/uv
EOF
```

### 3.3 Create Shared Python Venv and Auto-Activate

```bash
# Clone monorepo and build shared venv
ssh devadmin@$DEVBOX_IP bash -s << 'EOF'
  set -e
  git clone https://github.com/ColumbiaDataScienceCorporation/eq_tech.git /opt/eq-tech/repo
  uv venv /opt/eq-tech/venv --python python3.11
  uv pip install --python /opt/eq-tech/venv/bin/python \
    -r /opt/eq-tech/repo/requirements/dev.txt
  chown -R devadmin:devadmin /opt/eq-tech
  chmod -R 755 /opt/eq-tech/venv
EOF

# Auto-activate the venv on every SSH login
ssh devadmin@$DEVBOX_IP sudo tee /etc/profile.d/eq-tech-env.sh << 'EOF'
#!/bin/bash
if [ -f /opt/eq-tech/venv/bin/activate ]; then
    source /opt/eq-tech/venv/bin/activate
    export PYTHONPATH="/opt/eq-tech/repo:${PYTHONPATH}"
fi
EOF
ssh devadmin@$DEVBOX_IP sudo chmod +x /etc/profile.d/eq-tech-env.sh
```

### 3.4 Configure kubectl and Azure CLI on the Dev Server

Run these after Phase B creates the AKS cluster:

```bash
ssh devadmin@$DEVBOX_IP bash -s << 'EOF'
  az login
  az account set --subscription 0702e805-0c66-4bbd-9eb4-47ce81ecb369
  az aks get-credentials --resource-group eq-tech-rg --name eq-tech-aks --overwrite-existing
  kubectl get nodes  # confirm connectivity
EOF
```

### 3.5 Enable Per-Developer Disk Quotas

```bash
ssh devadmin@$DEVBOX_IP bash -s << 'EOF'
  set -e
  apt-get install -y -q quota
  if ! grep -q "usrquota" /etc/fstab; then
    sed -i '/[[:space:]]\//s/defaults/defaults,usrquota/' /etc/fstab
  fi
  mount -o remount /
  quotacheck -cum /
  quotaon /
EOF
```

Deploy the quota auto-scale cron script (see `implementation_plan.md` Phase 12.5 for full script content):

```bash
# Script auto-scales per-developer quotas every 15 min and expands the OS disk
# when overall utilisation exceeds 80%
ssh devadmin@$DEVBOX_IP sudo tee /etc/cron.d/eq-tech-quota-autoscale << 'CRON'
*/15 * * * * root /usr/local/bin/eq-tech-quota-autoscale.sh
CRON
```

---

## 4. Phase B: Shared Azure Infrastructure (One-Time)

This creates the resources shared across all environments. Run once from the dev server or your local workstation.

### 4.1 Bootstrap Terraform State Backend

```bash
az group create --name eq-tech-tfstate-rg --location eastus
az storage account create --name eqtechtfstate \
  --resource-group eq-tech-tfstate-rg --location eastus --sku Standard_LRS
az storage container create --name tfstate --account-name eqtechtfstate
```

### 4.2 Initialize Terraform and Create Workspaces

```bash
cd infra/terraform
terraform init

# Create all three workspaces (run once — these persist in the backend)
terraform workspace new dev
terraform workspace new uat
terraform workspace new prod
```

> **Note:** `terraform workspace new` only creates the workspace state slot. No resources are provisioned until you run `terraform apply`.

---

## 5. Phase C: Dev Environment Initialization

The dev environment is initialized first. It serves both as the live development environment and as the test bed for the CI/CD pipeline.

### 5.1 Provision Dev Infrastructure

```bash
cd infra/terraform
terraform workspace select dev
terraform apply \
  -var-file environments/dev.tfvars \
  -var "postgres_admin_password=<STRONG_PASSWORD>"
# dev.tfvars: 1 node, Standard_B2ms, B_Standard_B1ms PostgreSQL
```

Resources created or updated by this apply:
- AKS cluster `eq-tech-aks` (created on first apply; subsequent applies update it)
- PostgreSQL database `airflow_dev`
- ACR `eqtechacr` (shared across envs — created once by the first apply)
- Key Vault `eq-tech-kv` (shared — created once)

### 5.2 Create Kubernetes Namespaces

```bash
kubectl apply -f k8s/namespaces.yaml
```

### 5.3 Install NGINX Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace --set controller.replicaCount=1

# Wait for external IP; note it for all <LB_IP> placeholders
kubectl get svc -n ingress-nginx ingress-nginx-controller --watch
```

### 5.4 Update LB IP Placeholders

Once the LoadBalancer `EXTERNAL-IP` is known (e.g. `20.1.2.3`), update:
- `infra/helm/airflow-values.yaml` → `config.webserver.base_url`
- `infra/helm/airflow-values/dev.yaml`, `uat.yaml`, `prod.yaml` → host and base_url
- `infra/helm/oauth2-proxy-values.yaml` → redirect-url and ingress host
- `infra/helm/oauth2-proxy-values/dev.yaml`, `uat.yaml`, `prod.yaml`
- `k8s/ingress/ingress.yaml`
- Entra ID App Registration redirect URIs (Phase 4.4 of `implementation_plan.md`)

Commit these changes to `main`.

### 5.5 Create Per-Environment Kubernetes Secrets

```bash
PG_FQDN=$(terraform -chdir=infra/terraform output -raw postgres_fqdn)

# Dev environment secrets only at this stage
kubectl create secret generic airflow-postgres-secret \
  --namespace dev-airflow \
  --from-literal=connection="postgresql+psycopg2://airflow_admin:<PG_PASSWORD>@${PG_FQDN}/airflow_dev"

kubectl create secret generic github-git-sync-token \
  --namespace dev-airflow \
  --from-literal=GIT_SYNC_USERNAME=x-access-token \
  --from-literal=GIT_SYNC_PASSWORD=<GITHUB_FINE_GRAINED_PAT>

COOKIE_SECRET=$(python3 -c "import secrets,base64; print(base64.b64encode(secrets.token_bytes(16)).decode())")
kubectl create secret generic oauth2-proxy-secret \
  --namespace auth \
  --from-literal=client-id=<OAUTH2_CLIENT_ID> \
  --from-literal=client-secret=<OAUTH2_CLIENT_SECRET> \
  --from-literal=cookie-secret=$COOKIE_SECRET
```

### 5.6 Deploy OAuth2 Proxy (shared, one-time)

```bash
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests && helm repo update
helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy \
  --namespace auth \
  -f infra/helm/oauth2-proxy-values.yaml \
  -f infra/helm/oauth2-proxy-values/dev.yaml
```

### 5.7 Deploy Airflow to Dev

```bash
helm repo add apache-airflow https://airflow.apache.org && helm repo update
helm upgrade --install airflow-dev apache-airflow/airflow \
  --namespace dev-airflow --create-namespace \
  -f infra/helm/airflow-values.yaml \
  -f infra/helm/airflow-values/dev.yaml \
  --timeout 10m --atomic
```

### 5.8 Deploy Applications to Dev

```bash
az acr build --registry eqtechacr --image api:latest     --file apps/api/Dockerfile     apps/api
az acr build --registry eqtechacr --image ui-dash:latest --file apps/ui-dash/Dockerfile apps/ui-dash
az acr build --registry eqtechacr --image ui-web:latest  --file apps/ui-web/Dockerfile  apps/ui-web

kubectl apply -f k8s/apps/ -n dev-apps
kubectl apply -f k8s/ingress/ -n dev-apps
```

### 5.9 Verify Dev Environment

```bash
kubectl get pods -n dev-airflow   # all Running
kubectl get pods -n dev-apps      # api, dash-app, web-ui Running
kubectl get pods -n auth          # oauth2-proxy Running
kubectl get ingress -n dev-apps

# Browser checks
curl -f https://dev.eq-tech.<LB_IP>.nip.io/api/healthz
# → Browse https://dev.eq-tech.<LB_IP>.nip.io → redirects to Entra ID login
```

---

## 6. Phase D: UAT Environment Initialization

Initialize UAT when the first feature is stable in dev and ready for QA or stakeholder testing. **Do not initialize UAT prematurely** — it doubles Helm release count and PostgreSQL database count with no benefit until code is ready.

### 6.1 Provision UAT Infrastructure

```bash
cd infra/terraform
terraform workspace select uat
terraform apply \
  -var-file environments/uat.tfvars \
  -var "postgres_admin_password=<STRONG_PASSWORD>"
# uat.tfvars: 2 nodes, Standard_B4ms, B_Standard_B2ms PostgreSQL
# This creates airflow_uat database and updates the shared cluster with UAT node count
```

### 6.2 Create UAT Kubernetes Secrets

```bash
PG_FQDN=$(terraform -chdir=infra/terraform output -raw postgres_fqdn)

kubectl create secret generic airflow-postgres-secret \
  --namespace uat-airflow \
  --from-literal=connection="postgresql+psycopg2://airflow_admin:<PG_PASSWORD>@${PG_FQDN}/airflow_uat"

kubectl create secret generic github-git-sync-token \
  --namespace uat-airflow \
  --from-literal=GIT_SYNC_USERNAME=x-access-token \
  --from-literal=GIT_SYNC_PASSWORD=<GITHUB_FINE_GRAINED_PAT>
```

### 6.3 Update OAuth2 Proxy for UAT Domain

```bash
helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy \
  --namespace auth \
  -f infra/helm/oauth2-proxy-values.yaml \
  -f infra/helm/oauth2-proxy-values/uat.yaml
# uat.yaml adds uat.eq-tech.<LB_IP>.nip.io as an additional redirect URI host
```

### 6.4 Deploy Airflow to UAT

```bash
helm upgrade --install airflow-uat apache-airflow/airflow \
  --namespace uat-airflow --create-namespace \
  -f infra/helm/airflow-values.yaml \
  -f infra/helm/airflow-values/uat.yaml \
  --timeout 10m --atomic
```

### 6.5 Deploy Applications to UAT

```bash
kubectl apply -f k8s/apps/ -n uat-apps
kubectl apply -f k8s/ingress/ -n uat-apps
# Images are already in ACR from the dev build — no new build needed
LATEST_SHA=$(git rev-parse HEAD)
kubectl set image deployment/api    api=eqtechacr.azurecr.io/api:${LATEST_SHA}    -n uat-apps
kubectl set image deployment/dash-app dash-app=eqtechacr.azurecr.io/ui-dash:${LATEST_SHA} -n uat-apps
kubectl set image deployment/web-ui web-ui=eqtechacr.azurecr.io/ui-web:${LATEST_SHA} -n uat-apps
```

---

## 7. Phase E: Prod Environment Initialization

Initialize prod only after UAT has been validated by stakeholders and at least one full release cycle has run through the CI/CD promotion gates.

### 7.1 Provision Prod Infrastructure

```bash
cd infra/terraform
terraform workspace select prod
terraform apply \
  -var-file environments/prod.tfvars \
  -var "postgres_admin_password=<STRONG_PROD_PASSWORD>"
# prod.tfvars: 3 nodes, Standard_D4s_v3, GP_Standard_D2s_v3 PostgreSQL
# Use a DIFFERENT password from dev/uat
```

### 7.2 Create Prod Kubernetes Secrets

```bash
kubectl create secret generic airflow-postgres-secret \
  --namespace prod-airflow \
  --from-literal=connection="postgresql+psycopg2://airflow_admin:<PROD_PG_PASSWORD>@${PG_FQDN}/airflow_prod"

kubectl create secret generic github-git-sync-token \
  --namespace prod-airflow \
  --from-literal=GIT_SYNC_USERNAME=x-access-token \
  --from-literal=GIT_SYNC_PASSWORD=<GITHUB_FINE_GRAINED_PAT>
```

### 7.3 Deploy Airflow and Applications to Prod

```bash
helm upgrade --install airflow-prod apache-airflow/airflow \
  --namespace prod-airflow --create-namespace \
  -f infra/helm/airflow-values.yaml \
  -f infra/helm/airflow-values/prod.yaml \
  --timeout 10m --atomic

kubectl apply -f k8s/apps/ -n prod-apps
kubectl apply -f k8s/ingress/ -n prod-apps
```

---

## 8. Ongoing: Central Dev Server Maintenance

### 8.1 Update the Shared Python Venv

Run when `requirements/dev.txt` changes in the repo (the nightly cron also handles this automatically):

```bash
ssh devadmin@$DEVBOX_IP bash -s << 'EOF'
  cd /opt/eq-tech/repo
  git pull
  uv pip install --python /opt/eq-tech/venv/bin/python -r requirements/dev.txt
EOF
```

The nightly cron (2 AM) runs this automatically:
```
0 2 * * * devadmin cd /opt/eq-tech/repo && git pull && uv pip install \
  --python /opt/eq-tech/venv/bin/python -r requirements/dev.txt \
  >> /var/log/eq-tech-venv-sync.log 2>&1
```

### 8.2 Add a New Developer

```bash
NEW_USER=alice
DEVBOX_IP=$(az vm show --resource-group eq-tech-rg --name eq-tech-devbox \
  --show-details --query publicIps -o tsv)

ssh devadmin@$DEVBOX_IP bash -s << EOF
  useradd -m -s /bin/bash $NEW_USER
  mkdir -p /home/$NEW_USER/.ssh
  echo "<DEVELOPER_SSH_PUBLIC_KEY>" >> /home/$NEW_USER/.ssh/authorized_keys
  chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh
  chmod 700 /home/$NEW_USER/.ssh ; chmod 600 /home/$NEW_USER/.ssh/authorized_keys
  # 5 GB soft / 8 GB hard disk quota
  setquota -u $NEW_USER 5242880 8388608 0 0 /
EOF
```

### 8.3 OS Disk Quota Auto-Scaling

The cron script `/usr/local/bin/eq-tech-quota-autoscale.sh` runs every 15 minutes and:

1. **Checks overall disk usage** — if ≥ 80%, expands the OS managed disk by 64 GB online (using the VM's managed identity) then grows the LVM volume in-place
2. **Checks per-developer quota** — if a user is ≥ 80% of their hard limit, raises their soft limit by +2 GB and hard limit by +3 GB, up to a 50 GB ceiling that requires manual review

**View auto-scale history:**
```bash
ssh devadmin@$DEVBOX_IP sudo tail -50 /var/log/eq-tech-quota-autoscale.log
```

**View current disk and quota status:**
```bash
# Overall disk
ssh devadmin@$DEVBOX_IP df -h /

# Per-developer quota usage
ssh devadmin@$DEVBOX_IP sudo repquota -as /
```

**Manually raise a quota above the 50 GB ceiling:**
```bash
ssh devadmin@$DEVBOX_IP sudo setquota -u alice 62914560 73400320 0 0 /
# soft: 60 GB, hard: 70 GB
```

---

## 9. Ongoing: AKS Cluster Maintenance

### 9.1 Kubernetes Version Upgrades

Microsoft announces end-of-support for Kubernetes versions. Check and upgrade before the EOL date:

```bash
# Check available upgrades
az aks get-upgrades --resource-group eq-tech-rg --name eq-tech-aks -o table

# Upgrade the control plane (does not restart workloads immediately)
az aks upgrade --resource-group eq-tech-rg --name eq-tech-aks \
  --kubernetes-version 1.31

# Upgrade node pool (drains and recreates nodes one at a time)
az aks nodepool upgrade --resource-group eq-tech-rg \
  --cluster-name eq-tech-aks --name system --kubernetes-version 1.31
```

> **Best practice:** Upgrade Terraform's `kubernetes_version` in `main.tf` and `variables.tf` alongside the az CLI upgrade so the Terraform state stays consistent.

### 9.2 Helm Chart Updates

```bash
# Check for new Airflow chart versions
helm repo update
helm search repo apache-airflow/airflow --versions | head -5

# Upgrade (update airflowVersion in airflow-values.yaml first, then apply via CI)
# For emergency manual upgrade:
helm upgrade airflow-dev apache-airflow/airflow \
  --namespace dev-airflow \
  -f infra/helm/airflow-values.yaml \
  -f infra/helm/airflow-values/dev.yaml \
  --timeout 10m --atomic
```

### 9.3 AKS Node Auto-Provisioner (Preview)

For production, consider enabling AKS Node Auto-Provisioner (NAP) or the Cluster Autoscaler. Add to `variables.tf` and `main.tf`:

```hcl
# In azurerm_kubernetes_cluster
auto_scaler_profile {
  scale_down_delay_after_add = "10m"
  scan_interval              = "10s"
}
default_node_pool {
  ...
  enable_auto_scaling = true
  min_count           = var.aks_node_min_count
  max_count           = var.aks_node_max_count
}
```

---

## 10. Ongoing: PostgreSQL Maintenance

### 10.1 Automated Backups

The Flexible Server is configured with `backup_retention_days = 7`. Azure stores geo-redundant backups automatically. For production, increase to 30 days and enable geo-redundant backup:

```hcl
# In infra/terraform/environments/prod.tfvars
backup_retention_days        = 30
geo_redundant_backup_enabled = true
```

### 10.2 Check Database Size

```bash
PG_FQDN=$(terraform -chdir=infra/terraform output -raw postgres_fqdn)

psql "host=${PG_FQDN} dbname=airflow_dev user=airflow_admin sslmode=require" \
  -c "SELECT pg_size_pretty(pg_database_size('airflow_dev'));"
```

### 10.3 Airflow Metadata Cleanup

Airflow accumulates task instance and DAG run records over time. Run this periodically:

```bash
kubectl exec -n dev-airflow \
  $(kubectl get pod -n dev-airflow -l component=scheduler -o name | head -1) \
  -- airflow db clean --clean-before-timestamp "$(date -d '90 days ago' +'%Y-%m-%d')" --yes
```

### 10.4 PostgreSQL Version Upgrades

Azure manages minor version upgrades automatically. For major version upgrades (e.g., 15 → 16):
1. Update `version = "16"` in `main.tf`
2. Create a new server (Terraform creates it alongside the old one)
3. Migrate data using `pg_dump` / `pg_restore`
4. Update the K8s connection secret for each environment
5. Destroy the old server

---

## 11. Kubernetes Resource Quota Management

Without namespace-level resource quotas, a misbehaving pod in one environment can starve the others on the shared cluster. Apply a `ResourceQuota` and `LimitRange` to each application namespace.

### 11.1 Apply Resource Quotas per Environment

Create `k8s/quotas/` in the monorepo with per-namespace quotas:

**`k8s/quotas/dev-apps-quota.yaml`**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: dev-apps-quota
  namespace: dev-apps
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "20"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: dev-apps-limits
  namespace: dev-apps
spec:
  limits:
    - type: Container
      default:
        cpu: "500m"
        memory: "512Mi"
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
```

For UAT and prod, scale the numbers proportionally (e.g., prod: 8 CPU, 16 Gi). Apply:

```bash
kubectl apply -f k8s/quotas/
```

### 11.2 Check Resource Quota Usage

```bash
kubectl describe resourcequota -n dev-apps
kubectl describe resourcequota -n dev-airflow
kubectl top pods -n dev-apps
kubectl top pods -n dev-airflow
```

### 11.3 Airflow KubernetesExecutor Worker Quota

Worker pods are launched dynamically by the Airflow scheduler. Set a namespace-level quota on `dev-airflow` to cap concurrent workers:

```yaml
# Max 5 Airflow worker pods at once in dev
pods: "10"  # 5 workers + webserver + scheduler + git-sync + triggerer
```

---

## 12. Azure Subscription Quota Monitoring

The trial subscription has vCPU quotas. Running out silently causes VM creation to fail.

### 12.1 Check Current vCPU Usage

```bash
# Check quota for the region used (eastus)
az vm list-usage --location eastus --output table | grep -E "Name|vCPU|Standard_B"
```

### 12.2 Request Quota Increase

If you hit quota limits:
1. Navigate to: Azure Portal → Subscriptions → `0702e805...` → Usage + Quotas
2. Filter by region: eastus
3. Select the quota type → Request Increase

Typical quotas to watch for a 2-node B4ms cluster:
- `Total Regional vCPUs`: needs at least 8 (2 nodes × 4 vCPU)
- `Standard Bsv2 Family vCPUs` or `Standard Bv2 Family vCPUs` depending on the SKU

### 12.3 Automate Quota Alerting

```bash
# Set an Azure Monitor alert when vCPU usage exceeds 80% of quota
az monitor metrics alert create \
  --resource-group eq-tech-rg \
  --name "vCPU-quota-alert" \
  --scopes "/subscriptions/0702e805-0c66-4bbd-9eb4-47ce81ecb369" \
  --condition "avg Percentage CPU > 80" \
  --description "vCPU usage above 80% of quota"
```

---

## 13. Cost Management

### 13.1 Trial Account Budget

The Azure trial provides $200 USD. Estimated monthly burn:

| Resource | SKU (dev) | Est. Cost/month |
|---|---|---|
| AKS – 1× Standard_B2ms | 2 vCPU / 8 GB | ~$35 |
| PostgreSQL Flexible Server | B_Standard_B1ms | ~$15 |
| Azure Container Registry | Basic | ~$5 |
| Azure Key Vault | Standard | ~$1 |
| Developer VM | Standard_B2ms | ~$35 |
| **Dev only total** | | **~$91/month** |

Adding UAT (2 nodes B4ms) adds ~$140/month. Adding prod (3 nodes D4s_v3) adds ~$420/month.

**For the trial: only initialize dev.**

### 13.2 Stop the Dev Server When Not in Use

The auto-shutdown schedule (21:00 UTC) and idle-deallocate cron (§3.1b) handle this automatically. To manually restart:

```bash
az vm start --resource-group eq-tech-rg --name eq-tech-devbox
```

### 13.3 Scale AKS to Zero When Not Working

```bash
# Scale node pool to 0 (stops paying for VMs; control plane still billed at ~$72/month for paid tiers)
az aks nodepool scale \
  --resource-group eq-tech-rg --cluster-name eq-tech-aks \
  --name system --node-count 0
```

> **Note:** The AKS control plane on the Free tier has zero management fee. The trial `Standard_B4ms` node cost is the main driver.

---

## 14. Monitoring and Observability

### 14.1 Airflow Web UI

Available at `https://dev.eq-tech.<LB_IP>.nip.io/airflow/` after Entra ID login. Shows:
- DAG run history and task status
- Scheduler heartbeat health
- git-sync lag (last DAG sync time)

### 14.2 Kubernetes Pod Logs

```bash
# Airflow scheduler logs (includes git-sync activity)
kubectl logs -n dev-airflow -l component=scheduler -c scheduler --tail=100 -f
kubectl logs -n dev-airflow -l component=scheduler -c git-sync --tail=50

# API application logs
kubectl logs -n dev-apps -l app=api --tail=100 -f

# OAuth2 Proxy logs (useful for auth debugging)
kubectl logs -n auth -l app.kubernetes.io/name=oauth2-proxy --tail=100
```

### 14.3 Azure Monitor

The AKS cluster has Container Insights available. Enable it:

```bash
az aks enable-addons --resource-group eq-tech-rg --name eq-tech-aks \
  --addons monitoring \
  --workspace-resource-id /subscriptions/0702e805-0c66-4bbd-9eb4-47ce81ecb369/resourceGroups/eq-tech-rg/providers/Microsoft.OperationalInsights/workspaces/<YOUR_LAW_ID>
```

Key queries in Azure Monitor / Log Analytics:

```kusto
// Pod restarts in the last hour
KubePodInventory
| where TimeGenerated > ago(1h)
| where Namespace startswith "dev-" or Namespace == "auth"
| summarize Restarts = sum(PodRestartCount) by Name, Namespace
| where Restarts > 0

// Node CPU pressure
KubeNodeInventory
| where TimeGenerated > ago(15m)
| summarize avg(CpuCapacityNanoCores) by Computer
```

---

## 15. Backup and Recovery

### 15.1 PostgreSQL Point-in-Time Restore

Azure Flexible Server supports PITR for the configured retention period (7 days dev, 30 days prod). To restore:

```bash
az postgres flexible-server restore \
  --resource-group eq-tech-rg \
  --name eq-tech-pg-restored \
  --source-server eq-tech-pg \
  --restore-time "2026-09-20T10:00:00Z"
```

Update the K8s connection secret to point to the restored server, then restart Airflow.

### 15.2 Kubernetes Namespace Backup (Velero)

For production, install Velero to snapshot Kubernetes state (secrets, deployments, ConfigMaps):

```bash
velero install \
  --provider azure \
  --plugins velero/velero-plugin-for-microsoft-azure:v1.10.0 \
  --bucket velero-backups \
  --secret-file ./credentials-velero \
  --backup-location-config resourceGroup=eq-tech-rg,storageAccount=eqtechtfstate

# Schedule daily backups of prod namespaces
velero schedule create prod-daily \
  --schedule="0 2 * * *" \
  --include-namespaces prod-airflow,prod-apps,auth
```

### 15.3 Airflow DAG Recovery

Because DAGs are stored in Git (not on a persistent volume), DAG recovery is trivial:

```bash
# git-sync will re-sync all DAGs from main on next poll (max 30 seconds)
# If git-sync is broken, restart the scheduler pod:
kubectl rollout restart deployment/airflow-dev-scheduler -n dev-airflow
```
