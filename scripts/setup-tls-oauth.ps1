<#
.SYNOPSIS
    Installs cert-manager, provisions per-environment oauth2-proxy instances,
    applies TLS-enabled ingresses, and upgrades Airflow Helm releases to use HTTPS.

.DESCRIPTION
    Run once after merging the TLS/OAuth2 changes. Requires:
      - kubectl configured for eq-tech-aks
      - helm 3 on PATH
      - az CLI authenticated

    Manual prerequisite (Azure Portal -- cannot be automated):
      1. Entra app registration d5679b41-4dec-42e2-a2bc-7a884b6da06a
         -> Token configuration -> Add groups claim -> Security groups -> ID token
      2. Same app -> Authentication -> Add redirect URIs:
           https://dev.eq-tech.52.185.94.105.nip.io/oauth2/callback
           https://uat.eq-tech.52.185.94.105.nip.io/oauth2/callback
           https://eq-tech.52.185.94.105.nip.io/oauth2/callback

.EXAMPLE
    .\scripts\setup-tls-oauth.ps1
    .\scripts\setup-tls-oauth.ps1 -DryRun
#>
param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg) { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Skip([string]$msg) { Write-Host "    [--] $msg" -ForegroundColor DarkGray }

# --- 1. cert-manager -------------------------------------------------------
Write-Step "cert-manager"
$cmExists = kubectl get namespace cert-manager --ignore-not-found -o name 2>$null
if ($cmExists) {
    Write-Skip "cert-manager already installed -- skipping"
} else {
    Write-Host "    Installing cert-manager" -ForegroundColor DarkGray
    if (-not $DryRun) {
        kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
        kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s
    }
    Write-Ok "cert-manager installed"
}
Write-Host "    Applying letsencrypt-prod ClusterIssuer" -ForegroundColor DarkGray
if (-not $DryRun) { kubectl apply -f k8s/ingress/cluster-issuer.yaml }
Write-Ok "ClusterIssuer ready"

# --- 2. Per-environment oauth2-proxy --------------------------------------
Write-Step "Per-environment oauth2-proxy"
if (-not $DryRun) {
    helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests 2>$null
    helm repo update oauth2-proxy 2>$null
}

function Decode-B64([string]$b64) {
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
}
$plainClientId = ""; $plainClientSecret = ""; $plainCookieSecret = ""
if (-not $DryRun) {
    $plainClientId     = Decode-B64 (kubectl get secret oauth2-proxy -n auth -o jsonpath="{.data.client-id}")
    $plainClientSecret = Decode-B64 (kubectl get secret oauth2-proxy -n auth -o jsonpath="{.data.client-secret}")
    $plainCookieSecret = Decode-B64 (kubectl get secret oauth2-proxy -n auth -o jsonpath="{.data.cookie-secret}")
}

$nsMap = @{ dev = "dev-auth"; uat = "uat-auth"; prod = "prod-auth" }
foreach ($env in @("dev", "uat", "prod")) {
    $ns = $nsMap[$env]
    Write-Host "  [$env] -> $ns" -ForegroundColor DarkGray
    if (-not $DryRun) {
        kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
        kubectl create secret generic oauth2-proxy --namespace $ns --from-literal=client-id=$plainClientId --from-literal=client-secret=$plainClientSecret --from-literal=cookie-secret=$plainCookieSecret --dry-run=client -o yaml | kubectl apply -f -
        helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy --namespace $ns --values k8s/auth/oauth2-proxy-values-base.yaml --values "k8s/auth/oauth2-proxy-values-$env.yaml" --wait --timeout 120s
    }
    Write-Ok "oauth2-proxy deployed in $ns"
}

# --- 3. Retire old single proxy -------------------------------------------
Write-Step "Retiring old single oauth2-proxy in 'auth' namespace"
$oldRelease = helm list -n auth -q 2>$null | Where-Object { $_ -eq "oauth2-proxy" }
if ($oldRelease) {
    Write-Host "    helm uninstall oauth2-proxy -n auth" -ForegroundColor DarkGray
    if (-not $DryRun) { helm uninstall oauth2-proxy -n auth }
    Write-Ok "Old proxy removed"
} else {
    Write-Skip "No Helm release 'oauth2-proxy' in auth namespace"
}

# --- 4. Apply TLS app ingresses -------------------------------------------
Write-Step "Applying TLS app ingresses"
foreach ($env in @("dev", "uat", "prod")) {
    $ns = "$env-apps"
    Write-Host "    kubectl apply -f k8s/ingress/$env.yaml -n $ns" -ForegroundColor DarkGray
    if (-not $DryRun) { kubectl apply -f "k8s/ingress/$env.yaml" -n $ns }
    Write-Ok "Ingress updated for $ns"
}

# --- 5. Upgrade Airflow Helm releases -------------------------------------
Write-Step "Upgrading Airflow Helm releases with TLS ingress config"
$airflowReleases = @{ dev = "airflow-dev"; uat = "airflow-uat"; prod = "airflow-prod" }
$airflowNs       = @{ dev = "dev-airflow"; uat = "uat-airflow"; prod = "prod-airflow" }
foreach ($env in @("dev", "uat", "prod")) {
    $release = $airflowReleases[$env]
    $ns      = $airflowNs[$env]
    Write-Host "    helm upgrade $release -n $ns" -ForegroundColor DarkGray
    if (-not $DryRun) {
        helm upgrade $release apache-airflow/airflow --namespace $ns --reuse-values --values "infra/helm/airflow-values/$env.yaml" --timeout 300s
    }
    Write-Ok "Airflow $env ingress updated"
}

# --- 6. Re-enable FlaskGroupAuth on Dash ----------------------------------
Write-Step "Re-enabling FlaskGroupAuth on Dash"
foreach ($ns in @("dev-apps", "uat-apps", "prod-apps")) {
    Write-Host "    kubectl apply + rollout restart dash-app -n $ns" -ForegroundColor DarkGray
    if (-not $DryRun) {
        kubectl apply -f k8s/apps/dash-deployment.yaml -n $ns
        kubectl rollout restart deployment/dash-app -n $ns
    }
    Write-Ok "Dash restarted in $ns"
}

# --- 7. Wait for TLS certificates ----------------------------------------
Write-Step "Waiting for TLS certificates to be issued (up to 3 min per cert)"
if (-not $DryRun) {
    $timeout = 180
    $deadline = (Get-Date).AddSeconds($timeout)
    do {
        $notReady = kubectl get certificate -A --no-headers 2>$null |
                    Where-Object { $_ -notmatch "True" }
        if (-not $notReady) { break }
        Write-Host "    Pending certs: $($notReady.Count). Waiting..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)

    $certs = kubectl get certificate -A 2>$null
    Write-Host $certs
}

Write-Host "`n==> Done." -ForegroundColor Green
Write-Host "Next: verify in a browser" -ForegroundColor Cyan
Write-Host "  Dev  : https://dev.eq-tech.52.185.94.105.nip.io" -ForegroundColor Cyan
Write-Host "  UAT  : https://uat.eq-tech.52.185.94.105.nip.io" -ForegroundColor Cyan
Write-Host "  Prod : https://eq-tech.52.185.94.105.nip.io" -ForegroundColor Cyan
Write-Host "If Dash still 403s: confirm groups claim on Entra app + user group membership" -ForegroundColor Yellow

