<#
.SYNOPSIS
    Pauses the EQ Tech infrastructure to stop compute billing.
    Scales AKS to 0 nodes and stops PostgreSQL. ACR and Key Vault
    have negligible cost (~$6/month combined) and are left running.
    Run resume-infra.ps1 to bring everything back up.
#>
[CmdletBinding()]
param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RG = "eq-tech-rg"

function Write-Step([string]$msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "    [+] $msg" -ForegroundColor Green }
function Write-Skip([string]$msg) { Write-Host "    [-] $msg" -ForegroundColor DarkGray }

Write-Step "Pausing EQ Tech infrastructure"

# AKS: scale node pool to 0 (stops VM billing; Free-tier control plane has no cost)
$nodeCount = az aks show --resource-group $RG --name eq-tech-aks `
    --query "agentPoolProfiles[0].count" -o tsv
if ([int]$nodeCount -eq 0) {
    Write-Skip "AKS node pool already at 0"
} else {
    Write-Step "Scaling AKS node pool to 0 (from $nodeCount)"
    if (-not $DryRun) {
        az aks nodepool scale --resource-group $RG --cluster-name eq-tech-aks `
            --name system --node-count 0
        Write-Ok "AKS node pool scaled to 0"
    } else {
        Write-Skip "DryRun: would scale AKS to 0"
    }
}

# Dev VM: deallocate (auto-shutdown and idle-cron also handle this automatically)
$vmState = az vm show --resource-group $RG --name eq-tech-devbox `
    --query powerState -o tsv 2>$null
if ($null -eq $vmState -or $vmState -eq "") {
    Write-Skip "Dev VM not provisioned"
} elseif ($vmState -eq "VM deallocated") {
    Write-Skip "Dev VM already deallocated"
} else {
    Write-Step "Deallocating dev VM (state: $vmState)"
    if (-not $DryRun) {
        az vm deallocate --resource-group $RG --name eq-tech-devbox
        Write-Ok "Dev VM deallocated"
    } else {
        Write-Skip "DryRun: would deallocate dev VM"
    }
}

# PostgreSQL: stop server (still billed for storage at ~$3.68/month)
$pgState = az postgres flexible-server show --resource-group $RG --name eq-tech-pg `
    --query state -o tsv
if ($pgState -eq "Stopped") {
    Write-Skip "PostgreSQL already stopped"
} else {
    Write-Step "Stopping PostgreSQL ($pgState -> Stopped)"
    if (-not $DryRun) {
        az postgres flexible-server stop --resource-group $RG --name eq-tech-pg
        Write-Ok "PostgreSQL stop initiated (takes ~1 min)"
    } else {
        Write-Skip "DryRun: would stop PostgreSQL"
    }
}

Write-Host "`n>>> Infrastructure paused. Estimated running cost: ~`$4/month (storage only)." -ForegroundColor Yellow
Write-Host "    Run .\scripts\resume-infra.ps1 to restore." -ForegroundColor Yellow
