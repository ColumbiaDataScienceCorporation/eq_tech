<#
.SYNOPSIS
    Creates the eq-tech-secrets Kubernetes Secret in all three app namespaces.
    The secret contains EQTECH_POSTGRES_PASSWORD so the API pods can reach PostgreSQL.

.DESCRIPTION
    Reads PG_ADMIN_PASSWORD from Azure Key Vault (eq-tech-kv) and upserts the
    secret in dev-apps, uat-apps, and prod-apps namespaces.

.EXAMPLE
    .\scripts\create-pg-secrets.ps1
    .\scripts\create-pg-secrets.ps1 -Namespace dev-apps       # single namespace
    .\scripts\create-pg-secrets.ps1 -PgPassword "myPass"      # supply password directly
#>
param(
    [string]$Namespace = "all",          # "all" | "dev-apps" | "uat-apps" | "prod-apps"
    [string]$PgPassword = "",            # omit to read from Key Vault
    [string]$KeyVaultName = "eq-tech-kv",
    [string]$KvSecretName = "pg-admin-password"
)

$ErrorActionPreference = "Stop"

# ── Resolve the PostgreSQL password ─────────────────────────────────────────
if (-not $PgPassword) {
    Write-Host "Reading password from Key Vault '$KeyVaultName' / secret '$KvSecretName'..."
    try {
        $PgPassword = (az keyvault secret show `
            --vault-name $KeyVaultName `
            --name $KvSecretName `
            --query "value" -o tsv 2>$null)
    } catch {}

    if (-not $PgPassword) {
        # Fall back to local .env file (PG_ADMIN_PASSWORD)
        Write-Host "  Key Vault not reachable — falling back to .env file"
        $envFile = Join-Path $PSScriptRoot "..\\.env"
        if (Test-Path $envFile) {
            $PgPassword = (Get-Content $envFile |
                Where-Object { $_ -match "^PG_ADMIN_PASSWORD=" } |
                ForEach-Object { ($_ -split "=", 2)[1] } |
                Select-Object -First 1)
        }
    }

    if (-not $PgPassword) {
        Write-Error "Could not resolve PG password. Pass -PgPassword explicitly or ensure Key Vault / .env is accessible."
        exit 1
    }
}

# ── Choose target namespaces ─────────────────────────────────────────────────
$namespaces = if ($Namespace -eq "all") {
    @("dev-apps", "uat-apps", "prod-apps")
} else {
    @($Namespace)
}

# ── Upsert the secret in each namespace ─────────────────────────────────────
foreach ($ns in $namespaces) {
    Write-Host "`nNamespace: $ns"

    # Ensure namespace exists
    $nsExists = kubectl get namespace $ns --ignore-not-found -o name 2>$null
    if (-not $nsExists) {
        Write-Host "  Creating namespace $ns..."
        kubectl create namespace $ns
    }

    # Delete existing secret if present (idempotent upsert)
    $existing = kubectl get secret eq-tech-secrets -n $ns --ignore-not-found -o name 2>$null
    if ($existing) {
        Write-Host "  Deleting existing eq-tech-secrets..."
        kubectl delete secret eq-tech-secrets -n $ns
    }

    # Create fresh secret
    kubectl create secret generic eq-tech-secrets `
        --namespace $ns `
        --from-literal=EQTECH_POSTGRES_PASSWORD=$PgPassword

    Write-Host "  [OK] eq-tech-secrets created in $ns"
}

Write-Host "`nDone. Restart API pods to pick up the new secret:"
foreach ($ns in $namespaces) {
    Write-Host "  kubectl rollout restart deployment/api -n $ns"
}
