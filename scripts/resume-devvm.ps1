<#
.SYNOPSIS
    Starts the EQ Tech dev VM and prints the SSH connection string.
#>
param([switch]$DryRun)

$RG = "eq-tech-rg"
$VM = "eq-tech-devbox"

$state = az vm get-instance-view --resource-group $RG --name $VM `
    --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null

if (-not $state) { Write-Error "VM '$VM' not found in resource group '$RG'."; exit 1 }

if ($state -eq "VM running") {
    $ip = az vm show --resource-group $RG --name $VM --show-details --query publicIps -o tsv 2>$null
    Write-Host "[$VM] Already running -- SSH: devadmin@$ip" -ForegroundColor Green
    exit 0
}

Write-Host "[$VM] Current state: $state" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "[$VM] DryRun: would start VM." -ForegroundColor Yellow
    exit 0
}

Write-Host "[$VM] Starting..." -ForegroundColor Cyan
az vm start --resource-group $RG --name $VM
$ip = az vm show --resource-group $RG --name $VM --show-details --query publicIps -o tsv 2>$null
Write-Host "[$VM] Running -- SSH: devadmin@$ip" -ForegroundColor Green
