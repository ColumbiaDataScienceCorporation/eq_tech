<#
.SYNOPSIS
    Opens port-forwards for all EQ Tech services so you can reach them from localhost.
    Run in a dedicated terminal; press Ctrl+C to stop all forwards.

.PARAMETER Env
    Which environment(s) to forward. Defaults to all three.

.EXAMPLE
    .\scripts\port-forward.ps1
    .\scripts\port-forward.ps1 -Env dev
    .\scripts\port-forward.ps1 -Env dev,uat
#>
[CmdletBinding()]
param(
    [ValidateSet("dev","uat","prod")]
    [string[]]$Env = @("dev","uat","prod")
)

$ErrorActionPreference = "SilentlyContinue"

$FORWARDS = @(
    # Airflow UIs
    @{ env="dev";  ns="dev-airflow";   svc="airflow-dev-webserver";  local=8081; remote=8080; label="Airflow (dev)  " }
    @{ env="uat";  ns="uat-airflow";   svc="airflow-uat-webserver";  local=8082; remote=8080; label="Airflow (uat)  " }
    @{ env="prod"; ns="prod-airflow";  svc="airflow-prod-webserver"; local=8083; remote=8080; label="Airflow (prod) " }
    # APIs
    @{ env="dev";  ns="dev-apps";      svc="api-service";            local=8084; remote=8000; label="API     (dev)  " }
    @{ env="uat";  ns="uat-apps";      svc="api-service";            local=8085; remote=8000; label="API     (uat)  " }
    @{ env="prod"; ns="prod-apps";     svc="api-service";            local=8086; remote=8000; label="API     (prod) " }
    # Dash apps
    @{ env="dev";  ns="dev-apps";      svc="dash-service";           local=8087; remote=8050; label="Dash    (dev)  " }
    @{ env="uat";  ns="uat-apps";      svc="dash-service";           local=8088; remote=8050; label="Dash    (uat)  " }
    @{ env="prod"; ns="prod-apps";     svc="dash-service";           local=8089; remote=8050; label="Dash    (prod) " }
    # Web UIs
    @{ env="dev";  ns="dev-apps";      svc="web-service";            local=8090; remote=80;   label="Web UI  (dev)  " }
    @{ env="uat";  ns="uat-apps";      svc="web-service";            local=8091; remote=80;   label="Web UI  (uat)  " }
    @{ env="prod"; ns="prod-apps";     svc="web-service";            local=8092; remote=80;   label="Web UI  (prod) " }
)

$active = $FORWARDS | Where-Object { $Env -contains $_.env }

Write-Host ""
Write-Host "Starting port-forwards. Press Ctrl+C to stop all." -ForegroundColor Cyan
Write-Host ("-" * 60) -ForegroundColor DarkGray

$jobs = @()
foreach ($f in $active) {
    $svcExists = kubectl get svc $f.svc -n $f.ns 2>$null
    if (-not $svcExists) {
        Write-Host "  [--] $($f.label) svc/$($f.svc) not found in $($f.ns) -- skipping" -ForegroundColor DarkGray
        continue
    }
    $jobs += Start-Job -ScriptBlock {
        param($ns, $svc, $local, $remote)
        kubectl port-forward "svc/$svc" "${local}:${remote}" -n $ns 2>$null
    } -ArgumentList $f.ns, $f.svc, $f.local, $f.remote

    Write-Host "  [OK] $($f.label)  http://localhost:$($f.local)" -ForegroundColor Green
}

if ($jobs.Count -eq 0) {
    Write-Host "No services to forward." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "  Airflow login: admin / ChangeMe123!" -ForegroundColor DarkGray
Write-Host "  (Change the password at first login)" -ForegroundColor DarkGray
Write-Host ""

# Keep running until Ctrl+C
try {
    while ($true) { Start-Sleep -Seconds 5 }
} finally {
    $jobs | Stop-Job | Remove-Job
    Write-Host "`nPort-forwards stopped." -ForegroundColor Yellow
}
