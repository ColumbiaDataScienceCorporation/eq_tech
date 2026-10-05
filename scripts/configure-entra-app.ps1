<#
.SYNOPSIS
    Configures the Entra ID app registration for EQ Tech SSO.
    - Enables SecurityGroup membership claims in the ID token
    - Registers the three oauth2-proxy redirect URIs (dev, UAT, prod)

.EXAMPLE
    .\scripts\configure-entra-app.ps1
#>

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
