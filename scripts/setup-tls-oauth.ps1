<#
.SYNOPSIS
    Installs cert-manager, provisions per-environment oauth2-proxy instances,
    applies TLS-enabled ingresses, and upgrades Airflow Helm releases to use HTTPS.

.DESCRIPTION
    Run once after merging the TLS/OAuth2 changes. Requires:
      - kubectl configured for eq-tech-aks
      - helm 3 on PATH
      - az CLI authenticated

    Manual prerequisite (Azure Portal — cannot be automated):
      1. Entra app registration d5679b41-4dec-42e2-a2bc-7a884b6da06a
         → Token configuration → Add groups claim → Security groups → ID token
      2. Same app → Authentication → Add redirect URIs:
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
function Write-Ok([string]$msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Skip([string]$msg) { Write-Host "    [--] $msg" -ForegroundColor DarkGray }
function Invoke-Cmd([string]$desc, [scriptblock]$block) {
    Write-Host "    $desc" -ForegroundColor DarkGray
    if (-not $DryRun) { & $block }
}

# ── 1. cert-manager ───────────────────────────────────────────────────────────
Write-Step "cert-manager"
$cmExists = kubectl get namespace cert-manager --ignore-not-found -o name 2>$null
if ($cmExists) {
    Write-Skip "cert-manager namespace already exists — skipping install"
} else {
    Invoke-Cmd "Installing cert-manager CRDs + controller" {
        kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
    }
    Invoke-Cmd "Waiting for cert-manager webhook to be ready" {
        kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s
    }
    Write-Ok "cert-manager installed"
}

Invoke-Cmd "Applying letsencrypt-prod ClusterIssuer" {
    kubectl apply -f k8s/ingress/cluster-issuer.yaml
}
Write-Ok "ClusterIssuer ready"

# ── 2. Per-environment oauth2-proxy ───────────────────────────────────────────
Write-Step "Per-environment oauth2-proxy"

helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests 2>$null
helm repo update oauth2-proxy 2>$null

$envMap = @{
    dev  = @{ ns = "dev-auth";  host = "dev.eq-tech.52.185.94.105.nip.io" }
    uat  = @{ ns = "uat-auth";  host = "uat.eq-tech.52.185.94.105.nip.io" }
    prod = @{ ns = "prod-auth"; host = "eq-tech.52.185.94.105.nip.io"     }
}

# Read credentials from the existing proxy secret in the auth namespace
$clientId     = kubectl get secret oauth2-proxy -n auth -o jsonpath="{.data.client-id}"
$clientSecret = kubectl get secret oauth2-proxy -n auth -o jsonpath="{.data.client-secret}"
$cookieSecret = kubectl get secret oauth2-proxy -n auth -o jsonpath="{.data.cookie-secret}"

function Decode-B64([string]$b64) {
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
}
$plainClientId     = Decode-B64 $clientId
$plainClientSecret = Decode-B64 $clientSecret
$plainCookieSecret = Decode-B64 $cookieSecret

foreach ($env in @("dev","uat","prod")) {
    $cfg = $envMap[$env]
    $ns  = $cfg.ns

    Write-Host "  [$env] namespace: $ns" -ForegroundColor DarkGray

    Invoke-Cmd "  Creating namespace $ns" {
        kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
    }

    Invoke-Cmd "  Copying oauth2-proxy credentials to $ns" {
        kubectl create secret generic oauth2-proxy `
            --namespace $ns `
            --from-literal=client-id=$plainClientId `
            --from-literal=client-secret=$plainClientSecret `
            --from-literal=cookie-secret=$plainCookieSecret `
            --dry-run=client -o yaml | kubectl apply -f -
    }

    Invoke-Cmd "  Helm upgrade/install oauth2-proxy in $ns" {
        helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy `
            --namespace $ns `
            --values k8s/auth/oauth2-proxy-values-base.yaml `
            --values "k8s/auth/oauth2-proxy-values-$env.yaml" `
            --wait --timeout 120s
    }
    Write-Ok "oauth2-proxy deployed in $ns"
}

# ── 3. Retire the old single proxy ────────────────────────────────────────────
Write-Step "Retiring old single oauth2-proxy in 'auth' namespace"
$oldRelease = helm list -n auth -q 2>$null | Where-Object { $_ -eq "oauth2-proxy" }
if ($oldRelease) {
    Invoke-Cmd "helm uninstall oauth2-proxy -n auth" {
        helm uninstall oauth2-proxy -n auth
    }
    Write-Ok "Old proxy removed"
} else {
    Write-Skip "No Helm release 'oauth2-proxy' in auth namespace"
}

# ── 4. Apply TLS-enabled app ingresses ────────────────────────────────────────
Write-Step "Applying TLS app ingresses"
foreach ($env in @("dev","uat","prod")) {
    $ns = "$env-apps"
    Invoke-Cmd "kubectl apply -f k8s/ingress/$env.yaml -n $ns" {
        kubectl apply -f "k8s/ingress/$env.yaml" -n $ns
    }
    Write-Ok "Ingress updated for $ns"
}

# ── 5. Upgrade Airflow Helm releases with TLS ingress config ──────────────────
Write-Step "Upgrading Airflow Helm releases with TLS ingress config"
$airflowRelease = @{ dev = "airflow-dev"; uat = "airflow-uat"; prod = "airflow-prod" }
$airflowNs      = @{ dev = "dev-airflow"; uat = "uat-airflow"; prod = "prod-airflow" }

foreach ($env in @("dev","uat","prod")) {
    $release = $airflowRelease[$env]
    $ns      = $airflowNs[$env]
    Invoke-Cmd "helm upgrade $release -n $ns" {
        helm upgrade $release apache-airflow/airflow `
            --namespace $ns `
            --reuse-values `
            --values "infra/helm/airflow-values/$env.yaml" `
            --timeout 300s
    }
    Write-Ok "Airflow $env ingress updated"
}

# ── 6. Remove group-auth bypass from Dash deployments ─────────────────────────
Write-Step "Re-enabling FlaskGroupAuth on Dash (removing EQTECH_REQUIRE_GROUP_AUTH bypass)"
foreach ($ns in @("dev-apps","uat-apps","prod-apps")) {
    Invoke-Cmd "kubectl apply dash-deployment -n $ns" {
        kubectl apply -f k8s/apps/dash-deployment.yaml -n $ns
    }
    Invoke-Cmd "kubectl rollout restart deployment/dash-app -n $ns" {
        kubectl rollout restart deployment/dash-app -n $ns
    }
    Write-Ok "Dash restarted in $ns"
}

# ── 7. Wait for TLS certificates ──────────────────────────────────────────────
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
Write-Host @"

Next: verify in a browser
  Dev  : https://dev.eq-tech.52.185.94.105.nip.io
  UAT  : https://uat.eq-tech.52.185.94.105.nip.io
  Prod : https://eq-tech.52.185.94.105.nip.io

If Dash still returns 403 after login, confirm:
  - Groups claim is enabled on the Entra app registration
  - User is member of analysts or admins group
"@ -ForegroundColor Cyan
