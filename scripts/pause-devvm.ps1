<#
.SYNOPSIS
    Deallocates the EQ Tech dev VM to stop compute billing.
    Use resume-devvm.ps1 to bring it back.
#>
param([switch]$DryRun)

$RG = "eq-tech-rg"
$VM = "eq-tech-devbox"

$state = az vm get-instance-view --resource-group $RG --name $VM `
    --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null

if (-not $state) { Write-Error "VM '$VM' not found in resource group '$RG'."; exit 1 }

if ($state -eq "VM deallocated") {
    Write-Host "[$VM] Already deallocated." -ForegroundColor DarkGray
    exit 0
}

Write-Host "[$VM] Current state: $state" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "[$VM] DryRun: would deallocate." -ForegroundColor Yellow
    exit 0
}

Write-Host "[$VM] Deallocating..." -ForegroundColor Cyan
az vm deallocate --resource-group $RG --name $VM
Write-Host "[$VM] Deallocated. Compute billing stopped." -ForegroundColor Green
