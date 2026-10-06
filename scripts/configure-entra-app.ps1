<#
.SYNOPSIS
    Configures the Entra ID app registration for EQ Tech SSO and updates
    the oauth2-proxy k8s secrets in all three auth namespaces.
    - Enables SecurityGroup membership claims in the ID token
    - Registers the three oauth2-proxy redirect URIs (dev, UAT, prod)
    - Creates/resets a client secret and updates k8s secrets

.EXAMPLE
    .\scripts\configure-entra-app.ps1
    .\scripts\configure-entra-app.ps1 -SkipK8sSecrets   # Entra-only, skip k8s update
#>
param([switch]$SkipK8sSecrets)

$APP_ID  = "d5679b41-4dec-42e2-a2bc-7a884b6da06a"
$LB_IP   = "52.185.94.105"

$ErrorActionPreference = "Stop"

Write-Host "Configuring Entra app registration $APP_ID..." -ForegroundColor Cyan

az ad app update --id $APP_ID --set groupMembershipClaims=SecurityGroup
Write-Host "  [OK] groupMembershipClaims = SecurityGroup" -ForegroundColor Green

az ad app update --id $APP_ID --web-redirect-uris `
    "https://dev.eq-tech.$LB_IP.nip.io/oauth2/callback" `
    "https://uat.eq-tech.$LB_IP.nip.io/oauth2/callback" `
    "https://eq-tech.$LB_IP.nip.io/oauth2/callback"
Write-Host "  [OK] Redirect URIs registered" -ForegroundColor Green

Write-Host ""
az ad app show --id $APP_ID --query "{groupMembershipClaims:groupMembershipClaims, redirectUris:web.redirectUris}" -o json

if ($SkipK8sSecrets) { exit 0 }

# --- Update k8s oauth2-proxy secrets with real credentials ---
Write-Host "`nUpdating oauth2-proxy k8s secrets..." -ForegroundColor Cyan
$cred = az ad app credential reset --id $APP_ID --display-name "oauth2-proxy" -o json | ConvertFrom-Json
$clientSecret = $cred.password
# 32-character alphanumeric cookie secret (raw bytes, valid for AES cipher)
$cookieSecret = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })

foreach ($ns in @("dev-auth","uat-auth","prod-auth")) {
    kubectl delete secret oauth2-proxy -n $ns --ignore-not-found 2>$null
    kubectl create secret generic oauth2-proxy -n $ns `
        --from-literal=client-id=$APP_ID `
        --from-literal=client-secret=$clientSecret `
        --from-literal=cookie-secret=$cookieSecret
    kubectl rollout restart deployment/oauth2-proxy -n $ns 2>$null
    Write-Host "  [OK] $ns updated and restarted" -ForegroundColor Green
}
