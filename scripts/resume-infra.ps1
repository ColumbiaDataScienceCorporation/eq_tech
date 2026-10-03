<#
.SYNOPSIS
    Resumes the EQ Tech infrastructure after a pause or subscription re-activation.
    Scales AKS back to 1 node, starts PostgreSQL, refreshes kubectl credentials,
    and verifies all workloads are healthy. Auto-fixes NotReady nodes via VMSS restart.
#>
[CmdletBinding()]
param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RG          = "eq-tech-rg"
$CLUSTER     = "eq-tech-aks"
$PG_SERVER   = "eq-tech-pg"
$NODE_POOL   = "system"
$TARGET_NODES = 1

function Write-Step([string]$msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "    [+] $msg" -ForegroundColor Green }
function Write-Skip([string]$msg) { Write-Host "    [-] $msg" -ForegroundColor DarkGray }
function Write-Warn([string]$msg) { Write-Host "    [!] $msg" -ForegroundColor Yellow }

# ── 1. Resume PostgreSQL ───────────────────────────────────────────────────────
Write-Step "PostgreSQL"
$pgState = az postgres flexible-server show --resource-group $RG --name $PG_SERVER `
    --query state -o tsv

if ($pgState -eq "Ready") {
    Write-Ok "PostgreSQL already running"
} elseif ($pgState -in @("Stopped", "Stopping")) {
    if ($DryRun) { Write-Skip "DryRun: would start PostgreSQL"; }
    else {
        Write-Step "Starting PostgreSQL (state: $pgState)"
        az postgres flexible-server start --resource-group $RG --name $PG_SERVER
        Write-Ok "PostgreSQL start initiated (takes ~2 min to reach Ready)"
    }
} else {
    Write-Warn "PostgreSQL is in unexpected state: $pgState -- check the portal"
}

# ── 2. Resume AKS node pool ────────────────────────────────────────────────────
Write-Step "AKS node pool"
$nodeCount = az aks show --resource-group $RG --name $CLUSTER `
    --query "agentPoolProfiles[0].count" -o tsv
$powerState = az aks show --resource-group $RG --name $CLUSTER `
    --query "powerState.code" -o tsv

if ([int]$nodeCount -ge $TARGET_NODES -and $powerState -eq "Running") {
    Write-Ok "AKS node pool already at $nodeCount node(s)"
} else {
    if ($DryRun) { Write-Skip "DryRun: would scale AKS to $TARGET_NODES"; }
    else {
        Write-Step "Scaling AKS node pool to $TARGET_NODES (current: $nodeCount)"
        az aks nodepool scale --resource-group $RG --cluster-name $CLUSTER `
            --name $NODE_POOL --node-count $TARGET_NODES
        Write-Ok "AKS node pool scaled to $TARGET_NODES"
    }
}

# ── 3. Refresh kubectl credentials ────────────────────────────────────────────
Write-Step "Refreshing kubectl credentials"
if (-not $DryRun) {
    az aks get-credentials --resource-group $RG --name $CLUSTER --overwrite-existing
    Write-Ok "kubectl context updated"
}

if ($DryRun) {
    Write-Skip "DryRun: skipping node health check"
    exit 0
}

# ── 4. Wait for node to become Ready ──────────────────────────────────────────
Write-Step "Waiting for node to become Ready (up to 5 min)"
$deadline = (Get-Date).AddMinutes(5)
$nodeReady = $false
while ((Get-Date) -lt $deadline) {
    $nodeStatus = kubectl get nodes --no-headers 2>$null |
        ForEach-Object { ($_ -split '\s+')[1] }
    if ($nodeStatus -contains "Ready") {
        Write-Ok "Node is Ready"
        $nodeReady = $true
        break
    }
    Write-Host "    ... node status: $nodeStatus" -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
}

# ── 5. Auto-fix NotReady node via VMSS restart ────────────────────────────────
if (-not $nodeReady) {
    Write-Warn "Node did not become Ready within 5 min -- attempting VMSS restart"
    $MC_RG = az aks show --resource-group $RG --name $CLUSTER `
        --query nodeResourceGroup -o tsv
    $VMSS = az vmss list --resource-group $MC_RG `
        --query "[0].name" -o tsv

    Write-Step "Restarting VMSS instance ($MC_RG / $VMSS instance 0)"
    az vmss restart --resource-group $MC_RG --name $VMSS --instance-ids 0
    Write-Ok "VMSS restart triggered -- waiting 2 min for kubelet to recover"
    Start-Sleep -Seconds 120

    $nodeStatus = kubectl get nodes --no-headers 2>$null |
        ForEach-Object { ($_ -split '\s+')[1] }
    if ($nodeStatus -contains "Ready") {
        Write-Ok "Node is Ready after VMSS restart"
        $nodeReady = $true
    } else {
        Write-Warn "Node still not Ready after VMSS restart. Manual intervention needed."
        Write-Host "    Run: kubectl describe node" -ForegroundColor Yellow
    }
}

# ── 6. Verify pod health ───────────────────────────────────────────────────────
if ($nodeReady) {
    Write-Step "Checking pod health"
    $pendingPods = kubectl get pods --all-namespaces --no-headers 2>$null |
        Where-Object { $_ -match "Pending|CrashLoop|Error" }
    if ($pendingPods) {
        Write-Warn "Some pods are not healthy:"
        $pendingPods | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    } else {
        Write-Ok "All pods healthy"
    }

    Write-Step "Current cluster state"
    kubectl get nodes 2>$null
    kubectl get pods -n dev-airflow 2>$null
    kubectl get pods -n auth 2>$null
}

# ── 7. Confirm PostgreSQL is ready ─────────────────────────────────────────────
Write-Step "Confirming PostgreSQL state"
$pgFinal = az postgres flexible-server show --resource-group $RG --name $PG_SERVER `
    --query state -o tsv
if ($pgFinal -eq "Ready") {
    Write-Ok "PostgreSQL Ready"
} else {
    Write-Warn "PostgreSQL state: $pgFinal (may still be starting -- check again in a minute)"
}

Write-Host "`n>>> Resume complete." -ForegroundColor Green
