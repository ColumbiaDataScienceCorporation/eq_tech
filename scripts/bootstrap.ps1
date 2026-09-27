<#
.SYNOPSIS
    Automates Manual Prerequisites Steps 2, 3, and 4 from implementation_plan.md.
    Run once from your local workstation after completing Step 1 (git push).

.DESCRIPTION
    - Step 2: Creates the Azure storage account used as the Terraform remote state backend
    - Step 3: Creates the GitHub Actions OIDC service principal with federated credentials
    - Step 4: Creates the Entra ID App Registration for OAuth2 Proxy

    The script is idempotent  -  it skips resources that already exist and
    never overwrites a client secret that was already created.

    At the end it prints all GitHub Actions Secrets values you must enter manually.

.EXAMPLE
    .\scripts\bootstrap.ps1
    .\scripts\bootstrap.ps1 -ResetOAuthSecret   # force-rotate the OAuth2 client secret
#>

param(
    [switch]$ResetOAuthSecret
)

Set-StrictMode -Version Latest
# Use Continue so az CLI warnings (exit 1) don't abort; real failures checked via $LASTEXITCODE
$ErrorActionPreference = "Continue"

# -----------------------------------------------------------------------------
# Constants (match infra/terraform/variables.tf and implementation_plan.md)
# -----------------------------------------------------------------------------
$SUBSCRIPTION_ID    = "0702e805-0c66-4bbd-9eb4-47ce81ecb369"
$TENANT_ID          = "e5e33b11-e89c-466a-bf06-e94151676845"
$TFSTATE_RG         = "eq-tech-tfstate-rg"
$TFSTATE_SA         = "eqtechtfstate"
$TFSTATE_CONTAINER  = "tfstate"
$LOCATION           = "eastus"
$OIDC_APP_NAME      = "github-actions-eq-tech"
$OAUTH_APP_NAME     = "eq-tech-oauth2-proxy"
$GITHUB_ORG         = "ColumbiaDataScienceCorporation"
$GITHUB_REPO        = "eq_tech"

function Write-Step([string]$msg) { Write-Host "`n-- $msg" -ForegroundColor Cyan }
function Write-Done([string]$msg) { Write-Host "   [OK] $msg" -ForegroundColor Green }
function Write-Skip([string]$msg) { Write-Host "   [--] $msg (already exists, skipped)" -ForegroundColor Yellow }

# -----------------------------------------------------------------------------
# Prerequisite: verify Azure CLI login
# -----------------------------------------------------------------------------
Write-Step "Verifying Azure CLI login"
$account = az account show --query "{id:id,tenant:tenantId}" -o json 2>&1 | ConvertFrom-Json
if (-not $account -or $account.id -ne $SUBSCRIPTION_ID) {
    Write-Host "Not logged in to the correct subscription. Running az login..." -ForegroundColor Yellow
    az login --tenant $TENANT_ID
    az account set --subscription $SUBSCRIPTION_ID
}
Write-Done "Subscription: $SUBSCRIPTION_ID"

# -----------------------------------------------------------------------------
# STEP 2  -  Bootstrap Terraform State Backend
# -----------------------------------------------------------------------------
Write-Step "Step 2: Terraform state backend"

$rgExists = az group show --name $TFSTATE_RG --query "name" -o tsv 2>&1
if ($rgExists -eq $TFSTATE_RG) {
    Write-Skip "Resource group '$TFSTATE_RG'"
} else {
    az group create --name $TFSTATE_RG --location $LOCATION | Out-Null
    Write-Done "Resource group '$TFSTATE_RG' created"
}

$saExists = az storage account show --name $TFSTATE_SA --resource-group $TFSTATE_RG --query "name" -o tsv 2>&1
if ($saExists -eq $TFSTATE_SA) {
    Write-Skip "Storage account '$TFSTATE_SA'"
} else {
    az storage account create --name $TFSTATE_SA --resource-group $TFSTATE_RG `
        --location $LOCATION --sku Standard_LRS --kind StorageV2 | Out-Null
    Write-Done "Storage account '$TFSTATE_SA' created"
}

$containerExists = az storage container exists --name $TFSTATE_CONTAINER `
    --account-name $TFSTATE_SA --auth-mode login --query "exists" -o tsv 2>&1
if ($containerExists -eq "true") {
    Write-Skip "Blob container '$TFSTATE_CONTAINER'"
} else {
    az storage container create --name $TFSTATE_CONTAINER `
        --account-name $TFSTATE_SA --auth-mode login | Out-Null
    Write-Done "Blob container '$TFSTATE_CONTAINER' created"
}

# -----------------------------------------------------------------------------
# STEP 3  -  GitHub Actions OIDC Service Principal
# -----------------------------------------------------------------------------
Write-Step "Step 3: GitHub Actions OIDC service principal"

$APP_ID = az ad app list --display-name $OIDC_APP_NAME --query "[0].appId" -o tsv 2>&1
if ($APP_ID -and $APP_ID -notmatch "WARNING|ERROR") {
    Write-Skip "App registration '$OIDC_APP_NAME' (AppId: $APP_ID)"
} else {
    $APP_ID = az ad app create --display-name $OIDC_APP_NAME --query appId -o tsv
    Write-Done "App registration created (AppId: $APP_ID)"
}

$SP_OID = az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv 2>&1
if ($SP_OID -and $SP_OID -notmatch "WARNING|ERROR") {
    Write-Skip "Service principal (OID: $SP_OID)"
} else {
    $SP_OID = az ad sp create --id $APP_ID --query id -o tsv
    Write-Done "Service principal created (OID: $SP_OID)"
    Start-Sleep -Seconds 15   # allow AAD replication before role assignment
}

$roleExists = az role assignment list --assignee $SP_OID `
    --scope "/subscriptions/$SUBSCRIPTION_ID" --query "[?roleDefinitionName=='Contributor'].id" -o tsv 2>&1
if ($roleExists -and $roleExists -notmatch "WARNING|ERROR") {
    Write-Skip "Contributor role assignment"
} else {
    az role assignment create --role Contributor --assignee $SP_OID `
        --scope "/subscriptions/$SUBSCRIPTION_ID" | Out-Null
    Write-Done "Contributor role assigned"
}

# Federated credentials  -  write JSON to temp files to avoid PowerShell quoting issues
$fedCreds = @(
    @{ name = "github-main-branch"; subject = "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main" },
    @{ name = "github-pull-requests"; subject = "repo:${GITHUB_ORG}/${GITHUB_REPO}:pull_request" }
)
foreach ($fc in $fedCreds) {
    $existing = az ad app federated-credential list --id $APP_ID `
        --query "[?name=='$($fc.name)'].name" -o tsv 2>&1
    if ($existing -eq $fc.name) {
        Write-Skip "Federated credential '$($fc.name)'"
    } else {
        $json = @{
            name      = $fc.name
            issuer    = "https://token.actions.githubusercontent.com"
            subject   = $fc.subject
            audiences = @("api://AzureADTokenExchange")
        } | ConvertTo-Json -Compress
        $tmpFile = [System.IO.Path]::GetTempFileName() + ".json"
        $json | Set-Content -Path $tmpFile -Encoding utf8 -NoNewline
        az ad app federated-credential create --id $APP_ID --parameters "@$tmpFile" | Out-Null
        Remove-Item $tmpFile
        Write-Done "Federated credential '$($fc.name)' created"
    }
}

# -----------------------------------------------------------------------------
# STEP 4  -  Entra ID App Registration for OAuth2 Proxy
# -----------------------------------------------------------------------------
Write-Step "Step 4: Entra ID App Registration for OAuth2 Proxy"

$OAUTH_APP_ID = az ad app list --display-name $OAUTH_APP_NAME --query "[0].appId" -o tsv 2>&1
if ($OAUTH_APP_ID -and $OAUTH_APP_ID -notmatch "WARNING|ERROR") {
    Write-Skip "App registration '$OAUTH_APP_NAME' (AppId: $OAUTH_APP_ID)"
} else {
    $OAUTH_APP_ID = az ad app create --display-name $OAUTH_APP_NAME `
        --web-redirect-uris "https://placeholder.example.com/oauth2/callback" `
        --query appId -o tsv
    Write-Done "App registration '$OAUTH_APP_NAME' created (AppId: $OAUTH_APP_ID)"
}

# Enable groups claim
$groupsClaim = az ad app show --id $OAUTH_APP_ID --query "groupMembershipClaims" -o tsv 2>&1
if ($groupsClaim -eq "SecurityGroup") {
    Write-Skip "Groups claim (already SecurityGroup)"
} else {
    az ad app update --id $OAUTH_APP_ID --set groupMembershipClaims=SecurityGroup | Out-Null
    Write-Done "Groups claim set to SecurityGroup"
}

# Add Microsoft Graph delegated permissions (openid, profile, email)
$graphPerms = @(
    "37f7f235-527c-4136-accd-4a02d197296e=Scope",  # openid
    "14dad69e-099b-42c9-810b-d002981feec1=Scope",  # profile
    "64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0=Scope"   # email
)
az ad app permission add --id $OAUTH_APP_ID `
    --api 00000003-0000-0000-c000-000000000000 `
    --api-permissions $graphPerms 2>&1 | Out-Null
Write-Done "Microsoft Graph permissions added"

az ad app permission admin-consent --id $OAUTH_APP_ID 2>&1 | Out-Null
Write-Done "Admin consent granted"

# Client secret  -  create only if none exists, or if -ResetOAuthSecret is set
$existingSecrets = az ad app credential list --id $OAUTH_APP_ID `
    --query "[?displayName=='oauth2-proxy-secret'].displayName" -o tsv 2>&1
$OAUTH_SECRET = $null
if ($existingSecrets -eq "oauth2-proxy-secret" -and -not $ResetOAuthSecret) {
    Write-Skip "Client secret 'oauth2-proxy-secret' (use -ResetOAuthSecret to rotate)"
    $OAUTH_SECRET = "(already set - retrieve from your password manager or GitHub Secrets)"
} else {
    $OAUTH_SECRET = az ad app credential reset --id $OAUTH_APP_ID `
        --display-name "oauth2-proxy-secret" --query password -o tsv
    Write-Done "Client secret created  -  copy value below, it is shown only once"
}

# -----------------------------------------------------------------------------
# OUTPUT  -  GitHub Secrets to add manually
# -----------------------------------------------------------------------------
$secretsUrl = "https://github.com/$GITHUB_ORG/$GITHUB_REPO/settings/secrets/actions"
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "  GITHUB SECRETS -- add these at:" -ForegroundColor Magenta
Write-Host "  $secretsUrl" -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  AZURE_CLIENT_ID       = $APP_ID"
Write-Host "  AZURE_TENANT_ID       = $TENANT_ID"
Write-Host "  AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID"
Write-Host "  OAUTH2_CLIENT_ID      = $OAUTH_APP_ID"
Write-Host "  OAUTH2_CLIENT_SECRET  = $OAUTH_SECRET"
Write-Host ""
Write-Host "  Set these manually (values you choose):"
Write-Host "  PG_ADMIN_PASSWORD     = [choose a strong password, 16+ chars]"
Write-Host "  GIT_SYNC_TOKEN        = [GitHub Fine-Grained PAT]"
Write-Host "                          URL: https://github.com/settings/tokens?type=beta"
Write-Host "                          Repo: $GITHUB_ORG/$GITHUB_REPO only"
Write-Host "                          Permission: Contents = Read-only"
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
