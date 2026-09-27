<#
.SYNOPSIS
    Automates Steps 8-11: replace LB_IP, update Entra ID, create K8s secrets,
    deploy OAuth2 Proxy and Airflow dev.

.DESCRIPTION
    Step 8  [Phase 6, 7, k8s/ingress] - Replace <LB_IP> in all config files, commit, push
    Step 9  [Phase 4.4]               - Update Entra ID App Registration redirect URIs
    Step 10 [Phase 5.4]               - Create Kubernetes secrets (PG, git-sync, OAuth2 Proxy)
    Step 11 [Phase 6 + Phase 7]       - Deploy OAuth2 Proxy and Airflow dev via Helm

    Reads PG_ADMIN_PASSWORD and GIT_SYNC_TOKEN from c:\eq_tech\.env automatically.
    Rotates the OAuth2 client secret (the previously issued secret was exposed in session
    logs; rotation invalidates it and produces a fresh value used for the K8s secret).

.EXAMPLE
    .\scripts\finish-dev.ps1
#>

param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH", "User") + ";" +
            "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin"

$REPO_ROOT      = Split-Path -Parent $PSScriptRoot
$SUBSCRIPTION   = "0702e805-0c66-4bbd-9eb4-47ce81ecb369"
$TENANT         = "e5e33b11-e89c-466a-bf06-e94151676845"
$OAUTH_APP_ID   = "0736bbdd-a44b-41c1-8e3a-598224e04261"
$TF_DIR         = Join-Path $REPO_ROOT "infra\terraform"

function Write-Step([string]$msg) { Write-Host "`n-- $msg" -ForegroundColor Cyan }
function Write-Done([string]$msg) { Write-Host "   [OK] $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "   [..] $msg" -ForegroundColor Yellow }

# ── Read .env file ────────────────────────────────────────────────────────────
Write-Step "Reading credentials from .env"
$envFile = Join-Path $REPO_ROOT ".env"
if (-not (Test-Path $envFile)) {
    Write-Host "ERROR: $envFile not found. Create it with PG_ADMIN_PASSWORD and GIT_SYNC_TOKEN." -ForegroundColor Red
    exit 1
}
$dotenv = @{}
Get-Content $envFile | Where-Object { $_ -match '^\s*([^#=\s]+)\s*=\s*(.+)\s*$' } |
    ForEach-Object { $dotenv[$Matches[1]] = $Matches[2].Trim() }

$PG_PASSWORD    = $dotenv["PG_ADMIN_PASSWORD"]
$GIT_SYNC_TOKEN = $dotenv["GIT_SYNC_TOKEN"]

if (-not $PG_PASSWORD -or -not $GIT_SYNC_TOKEN) {
    Write-Host "ERROR: PG_ADMIN_PASSWORD and GIT_SYNC_TOKEN must be set in .env" -ForegroundColor Red
    exit 1
}
Write-Done "Credentials loaded from .env"

# ── Verify Azure login ────────────────────────────────────────────────────────
Write-Step "Verifying Azure login"
$sub = az account show --query "id" -o tsv 2>&1
if ($sub -ne $SUBSCRIPTION) {
    az login --tenant $TENANT ; az account set --subscription $SUBSCRIPTION
}
Write-Done "Subscription: $SUBSCRIPTION"

# ── Get LB IP from cluster ────────────────────────────────────────────────────
Write-Step "Getting LoadBalancer IP"
$LB_IP = kubectl get svc -n ingress-nginx ingress-nginx-controller `
    --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
if (-not $LB_IP) {
    Write-Host "ERROR: Cannot get LB IP. Is NGINX Ingress running?" -ForegroundColor Red
    exit 1
}
Write-Done "LB_IP = $LB_IP"

# ── Rotate OAuth2 client secret (previous value was exposed in session logs) ──
Write-Step "Rotating OAuth2 client secret"
$OAUTH_SECRET = az ad app credential reset --id $OAUTH_APP_ID `
    --display-name "oauth2-proxy-secret" --query password -o tsv 2>&1
if (-not $OAUTH_SECRET -or $OAUTH_SECRET -match "ERROR") {
    Write-Host "ERROR rotating OAuth2 secret: $OAUTH_SECRET" -ForegroundColor Red
    exit 1
}
Write-Done "OAuth2 client secret rotated"

# ── Generate OAuth2 Proxy cookie secret ───────────────────────────────────────
$COOKIE_SECRET = [Convert]::ToBase64String((1..16 | ForEach-Object { [byte](Get-Random -Max 256) }))

# ── Get PostgreSQL FQDN ───────────────────────────────────────────────────────
Write-Step "Getting PostgreSQL FQDN from Terraform state"
Push-Location $TF_DIR
terraform workspace select dev | Out-Null
$PG_FQDN = terraform output -raw postgres_fqdn 2>&1
Pop-Location
if (-not $PG_FQDN -or $PG_FQDN -match "Error") {
    Write-Host "ERROR: Cannot get postgres_fqdn from Terraform. Is the dev workspace applied?" -ForegroundColor Red
    exit 1
}
Write-Done "PostgreSQL FQDN = $PG_FQDN"

# ────────────────────────────────────────────────────────────────────────────────
# STEP 8: Replace <LB_IP> in all config files, then commit and push
# ────────────────────────────────────────────────────────────────────────────────
Write-Step "Step 8: Replacing <LB_IP> with $LB_IP in all config files"
Set-Location $REPO_ROOT
$count = 0
Get-ChildItem -Recurse -File . |
    Where-Object { $_.Extension -in '.yaml', '.yml', '.tf', '.tfvars' -and $_.FullName -notmatch '\\\.terraform\\' } |
    ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        if ($content -match '<LB_IP>') {
            ($content -replace '<LB_IP>', $LB_IP) | Set-Content $_.FullName -NoNewline
            $count++
        }
    }
Write-Done "$count files updated"

$remaining = (Get-ChildItem -Recurse -File . |
    Where-Object { $_.Extension -in '.yaml','.yml','.tf','.tfvars' } |
    Select-String "<LB_IP>" | Measure-Object).Count
if ($remaining -gt 0) {
    Write-Host "   WARNING: $remaining files still contain <LB_IP>" -ForegroundColor Yellow
}

Write-Info "Committing and pushing..."
git add .
git commit -m "chore: resolve LB_IP placeholders ($LB_IP)"
git push origin main
if ($LASTEXITCODE -eq 0) {
    Write-Done "Pushed to main -- GitHub Actions CI/CD triggered"
} else {
    Write-Host "   WARNING: git push failed. Push manually: git push origin main" -ForegroundColor Yellow
}

# ────────────────────────────────────────────────────────────────────────────────
# STEP 9: Update Entra ID App Registration redirect URIs
# ────────────────────────────────────────────────────────────────────────────────
Write-Step "Step 9: Updating Entra ID redirect URIs"
az ad app update --id $OAUTH_APP_ID --web-redirect-uris `
    "https://dev.eq-tech.$LB_IP.nip.io/oauth2/callback" `
    "https://uat.eq-tech.$LB_IP.nip.io/oauth2/callback" `
    "https://eq-tech.$LB_IP.nip.io/oauth2/callback" | Out-Null
Write-Done "Redirect URIs updated"

# ────────────────────────────────────────────────────────────────────────────────
# STEP 10: Create Kubernetes secrets
# ────────────────────────────────────────────────────────────────────────────────
Write-Step "Step 10: Creating Kubernetes secrets"

# Airflow PG + git-sync secrets in every airflow namespace
foreach ($ENV in @("dev", "uat", "prod")) {
    $NS = "${ENV}-airflow"
    Write-Info "Creating secrets in $NS"

    kubectl create secret generic airflow-postgres-secret --namespace $NS `
        --from-literal=connection="postgresql+psycopg2://airflow_admin:${PG_PASSWORD}@${PG_FQDN}/airflow_${ENV}" `
        --dry-run=client -o yaml | kubectl apply -f - | Out-Null

    kubectl create secret generic github-git-sync-token --namespace $NS `
        --from-literal=GIT_SYNC_USERNAME=x-access-token `
        --from-literal=GIT_SYNC_PASSWORD=$GIT_SYNC_TOKEN `
        --dry-run=client -o yaml | kubectl apply -f - | Out-Null

    Write-Done "Secrets applied in $NS"
}

# OAuth2 Proxy secret in auth namespace (shared)
kubectl create secret generic oauth2-proxy-secret --namespace auth `
    --from-literal=client-id=$OAUTH_APP_ID `
    --from-literal=client-secret=$OAUTH_SECRET `
    --from-literal=cookie-secret=$COOKIE_SECRET `
    --dry-run=client -o yaml | kubectl apply -f - | Out-Null
Write-Done "oauth2-proxy-secret applied in auth"

# ────────────────────────────────────────────────────────────────────────────────
# STEP 11: Deploy OAuth2 Proxy and Airflow dev
# ────────────────────────────────────────────────────────────────────────────────
Write-Step "Step 11: Deploying OAuth2 Proxy"
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests 2>&1 | Out-Null
helm repo update 2>&1 | Out-Null
helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy `
    --namespace auth `
    -f "$REPO_ROOT\infra\helm\oauth2-proxy-values.yaml" `
    -f "$REPO_ROOT\infra\helm\oauth2-proxy-values\dev.yaml"
Write-Done "OAuth2 Proxy deployed"

Write-Step "Step 11: Deploying Airflow (dev)"
helm repo add apache-airflow https://airflow.apache.org 2>&1 | Out-Null
helm repo update 2>&1 | Out-Null
helm upgrade --install airflow-dev apache-airflow/airflow `
    --namespace dev-airflow `
    --create-namespace `
    -f "$REPO_ROOT\infra\helm\airflow-values.yaml" `
    -f "$REPO_ROOT\infra\helm\airflow-values\dev.yaml" `
    --timeout 10m `
    --atomic
Write-Done "Airflow dev deployed"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "  Steps 8-11 complete." -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  IMPORTANT: Update the GitHub Secret OAUTH2_CLIENT_SECRET"
Write-Host "  with the new rotated value at:"
Write-Host "  https://github.com/ColumbiaDataScienceCorporation/eq_tech/settings/secrets/actions"
Write-Host ""
Write-Host "  The new value was used for the K8s secret and Helm deploy."
Write-Host "  (Do NOT print it here -- retrieve it from your password manager"
Write-Host "   or run: az ad app credential list --id $OAUTH_APP_ID)"
Write-Host ""
Write-Host "  NEXT: Step 12 -- change Airflow admin password at:"
Write-Host "  https://dev.eq-tech.$LB_IP.nip.io/airflow/"
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
