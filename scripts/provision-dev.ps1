<#
.SYNOPSIS
    Automates Steps 7 and 7e of implementation_plan.md: provision dev infrastructure,
    install NGINX Ingress, create the Entra ID group ConfigMaps, then output the
    LoadBalancer IP needed for Step 8.

.DESCRIPTION
    7a - Terraform: init, create workspaces, apply dev environment
    7b - AKS: pull kubeconfig, install NGINX Ingress Controller via Helm
    7c - Kubernetes: create all environment namespaces
    7d - Wait for LoadBalancer external IP and print it
    7e - Create eq-tech-groups ConfigMap in every app namespace

    Run this script after completing Steps 1-6 of the Manual Prerequisites Checklist.
    When it finishes, copy the LB_IP it prints and proceed with Step 8.

.PARAMETER AnalystsGroupId
    Entra ID Object ID for the analysts security group (from Step 6b).

.PARAMETER PortfolioManagersGroupId
    Entra ID Object ID for the portfolio managers security group (from Step 6b).

.PARAMETER RiskGroupId
    Entra ID Object ID for the risk security group (from Step 6b).

.PARAMETER AdminsGroupId
    Entra ID Object ID for the admins security group (from Step 6b).

.EXAMPLE
    .\scripts\provision-dev.ps1 `
        -AnalystsGroupId         e5027eb5-1610-4b88-b68e-8b59af3e3052 `
        -PortfolioManagersGroupId c6a15f1b-fe3e-4419-b43e-a740a9366b1f `
        -RiskGroupId             e9d1a418-656c-4721-96e7-be308c809e44 `
        -AdminsGroupId           4d39f097-51ec-46c5-a2ac-9f49b86eb28d
#>

param(
    [string]$AnalystsGroupId          = "",
    [string]$PortfolioManagersGroupId = "",
    [string]$RiskGroupId              = "",
    [string]$AdminsGroupId            = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH", "User") + ";" +
            "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin"

$REPO_ROOT      = Split-Path -Parent $PSScriptRoot
$TF_DIR         = Join-Path $REPO_ROOT "infra\terraform"
$K8S_DIR        = Join-Path $REPO_ROOT "k8s"
$RG             = "eq-tech-rg"
$AKS            = "eq-tech-aks"
$SUBSCRIPTION   = "0702e805-0c66-4bbd-9eb4-47ce81ecb369"

function Write-Step([string]$msg) { Write-Host "`n-- $msg" -ForegroundColor Cyan }
function Write-Done([string]$msg) { Write-Host "   [OK] $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "   [..] $msg" -ForegroundColor Yellow }

# ── Verify Azure login ────────────────────────────────────────────────────────
Write-Step "Verifying Azure CLI login"
$subId = az account show --query "id" -o tsv 2>&1
if ($subId -ne $SUBSCRIPTION) {
    Write-Host "Not logged in to the correct subscription. Running az login..." -ForegroundColor Yellow
    az login --tenant "e5e33b11-e89c-466a-bf06-e94151676845"
    az account set --subscription $SUBSCRIPTION
}
Write-Done "Subscription: $SUBSCRIPTION"

# ── 7a: Terraform init + workspaces + apply (dev) ────────────────────────────
Write-Step "7a: Terraform init and workspace setup"
Set-Location $TF_DIR

terraform init | Out-Null
Write-Done "terraform init complete"

foreach ($ws in @("dev", "uat", "prod")) {
    $exists = terraform workspace list 2>&1 | Select-String "^\s+$ws\s*$"
    if (-not $exists) {
        terraform workspace new $ws | Out-Null
        Write-Done "Workspace '$ws' created"
    } else {
        Write-Info "Workspace '$ws' already exists"
    }
}

terraform workspace select dev | Out-Null
Write-Done "Selected workspace: dev"

Write-Step "7a: Terraform apply (dev) -- this takes ~10 minutes for AKS"

# Prompt securely; value stays in this process only
if (-not $env:TF_VAR_postgres_admin_password) {
    $env:TF_VAR_postgres_admin_password = Read-Host "PostgreSQL admin password"
}

terraform apply -var-file environments/dev.tfvars -auto-approve
if ($LASTEXITCODE -ne 0) {
    Write-Host "Terraform apply failed. Check errors above." -ForegroundColor Red
    exit 1
}
Write-Done "Infrastructure provisioned"

# ── 7b: AKS kubeconfig + NGINX Ingress ───────────────────────────────────────
Write-Step "7b: Pull AKS kubeconfig"
Set-Location $REPO_ROOT
az aks get-credentials --resource-group $RG --name $AKS --overwrite-existing
Write-Done "kubeconfig updated"

Write-Step "7b: Install NGINX Ingress Controller"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>&1 | Out-Null
helm repo update 2>&1 | Out-Null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
    --namespace ingress-nginx `
    --create-namespace `
    --set controller.replicaCount=1
Write-Done "NGINX Ingress installed"

# ── 7c: Create Kubernetes namespaces ─────────────────────────────────────────
Write-Step "7c: Create Kubernetes namespaces"
kubectl apply -f "$K8S_DIR\namespaces.yaml"
Write-Done "Namespaces created"

# ── 7d: Wait for LoadBalancer IP ─────────────────────────────────────────────
Write-Step "7d: Waiting for LoadBalancer IP (up to 5 minutes)"
$LB_IP = ""
$tries  = 0
$maxTries = 30   # 30 x 10s = 5 minutes
while (-not $LB_IP -and $tries -lt $maxTries) {
    Start-Sleep 10
    $LB_IP = kubectl get svc -n ingress-nginx ingress-nginx-controller `
        --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
    $tries++
    if (-not $LB_IP) {
        Write-Info "Still waiting... ($($tries * 10)s elapsed)"
    }
}

if ($LB_IP) {
    Write-Done "LoadBalancer IP assigned: $LB_IP"
} else {
    Write-Host "IP not yet assigned. Check manually:" -ForegroundColor Yellow
    Write-Host "  kubectl get svc -n ingress-nginx ingress-nginx-controller"
    $LB_IP = Read-Host "Enter the IP once it appears"
}

# ── 7e: Entra ID group ConfigMaps ────────────────────────────────────────────
Write-Step "7e: Create eq-tech-groups ConfigMap in all app namespaces"

# Prompt for any group ID not supplied as a parameter
if (-not $AnalystsGroupId)          { $AnalystsGroupId          = Read-Host "Analysts group Object ID (Step 6b)" }
if (-not $PortfolioManagersGroupId) { $PortfolioManagersGroupId = Read-Host "Portfolio Managers group Object ID (Step 6b)" }
if (-not $RiskGroupId)              { $RiskGroupId              = Read-Host "Risk group Object ID (Step 6b)" }
if (-not $AdminsGroupId)            { $AdminsGroupId            = Read-Host "Admins group Object ID (Step 6b)" }

foreach ($NS in @("dev-apps", "uat-apps", "prod-apps")) {
    $existing = kubectl get configmap eq-tech-groups --namespace $NS 2>&1
    if ($existing -match "eq-tech-groups") {
        # Replace in-place so the values stay current on re-runs
        kubectl create configmap eq-tech-groups --namespace $NS --dry-run=client -o yaml `
            --from-literal=EQTECH_ANALYSTS_GROUP_ID=$AnalystsGroupId `
            --from-literal=EQTECH_PORTFOLIO_MANAGERS_GROUP_ID=$PortfolioManagersGroupId `
            --from-literal=EQTECH_RISK_GROUP_ID=$RiskGroupId `
            --from-literal=EQTECH_ADMINS_GROUP_ID=$AdminsGroupId | kubectl apply -f -
        Write-Done "ConfigMap updated in $NS"
    } else {
        kubectl create configmap eq-tech-groups --namespace $NS `
            --from-literal=EQTECH_ANALYSTS_GROUP_ID=$AnalystsGroupId `
            --from-literal=EQTECH_PORTFOLIO_MANAGERS_GROUP_ID=$PortfolioManagersGroupId `
            --from-literal=EQTECH_RISK_GROUP_ID=$RiskGroupId `
            --from-literal=EQTECH_ADMINS_GROUP_ID=$AdminsGroupId
        Write-Done "ConfigMap created in $NS"
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "  Step 7 complete. NEXT: Step 8 -- replace <LB_IP> in config files" -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  LB_IP = $LB_IP"
Write-Host ""
Write-Host "  Run this to replace all placeholders, then commit and push:"
Write-Host ""
Write-Host "  `$LB_IP = '$LB_IP'"
Write-Host "  Get-ChildItem -Recurse -File . |"
Write-Host "    Where-Object { `$_.Extension -in '.yaml','.yml','.tf','.tfvars' } |"
Write-Host "    ForEach-Object {"
Write-Host "      `$c = Get-Content `$_.FullName -Raw"
Write-Host "      if (`$c -match '<LB_IP>') {"
Write-Host "        (`$c -replace '<LB_IP>', `$LB_IP) | Set-Content `$_.FullName -NoNewline"
Write-Host "        Write-Host `"Updated: `$(`$_.FullName)`""
Write-Host "      }"
Write-Host "    }"
Write-Host ""
Write-Host "  Then: git add . ; git commit -m 'chore: resolve LB_IP ($LB_IP)' ; git push origin main"
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
