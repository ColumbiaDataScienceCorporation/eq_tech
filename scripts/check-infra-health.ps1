<#
.SYNOPSIS
    Checks the health of the EQ Tech platform and prints a summary with URLs.
    Covers Azure resources, Kubernetes workloads, and HTTP endpoints.

.EXAMPLE
    cd c:\eq_tech
    .\scripts\check-infra-health.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "SilentlyContinue"
$RG = "eq-tech-rg"

# ── Helpers ────────────────────────────────────────────────────────────────────
function OK    { param($t) Write-Host "  [OK]  $t" -ForegroundColor Green }
function WARN  { param($t) Write-Host "  [!!]  $t" -ForegroundColor Yellow }
function FAIL  { param($t) Write-Host "  [XX]  $t" -ForegroundColor Red }
function INFO  { param($t) Write-Host "  [--]  $t" -ForegroundColor DarkGray }
function HEAD  { param($t) Write-Host "`n$t" -ForegroundColor Cyan ; Write-Host ("-" * 72) -ForegroundColor DarkGray }

$script:ok   = 0
$script:warn = 0
$script:fail = 0

function Tally { param($status)
    switch ($status) { "OK" { $script:ok++ } "WARN" { $script:warn++ } "FAIL" { $script:fail++ } }
}

function Test-Endpoint {
    param([string]$url, [int]$timeout = 8)
    try {
        $r = Invoke-WebRequest -Uri $url -TimeoutSec $timeout -SkipCertificateCheck `
             -MaximumRedirection 0 -ErrorAction Stop
        return @{ code = $r.StatusCode; ok = $true }
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -and $code -lt 500) { return @{ code = $code; ok = $true } }
        $errCode = if ($code) { $code } else { "ERR" }
        return @{ code = $errCode; ok = $false }
    }
}

Write-Host ""
Write-Host ("=" * 72)
Write-Host ("  EQ TECH INFRASTRUCTURE HEALTH  {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC" -AsUTC))
Write-Host ("=" * 72)

# ── 1. Azure Resources ─────────────────────────────────────────────────────────
HEAD "1. AZURE RESOURCES"

# AKS
$aks = az aks show --resource-group $RG --name eq-tech-aks `
    --query "{nodes:agentPoolProfiles[0].count, power:powerState.code, k8s:kubernetesVersion}" -o json 2>$null | ConvertFrom-Json
if ($aks) {
    $msg = "AKS  eq-tech-aks   k8s $($aks.k8s)  $($aks.nodes) node(s)  $($aks.power)"
    if ($aks.power -eq "Running") { OK $msg; Tally "OK" } else { WARN $msg; Tally "WARN" }
} else { FAIL "AKS  eq-tech-aks   unreachable"; Tally "FAIL" }

# PostgreSQL
$pg = az postgres flexible-server show --resource-group $RG --name eq-tech-pg `
    --query "{state:state, sku:sku.name}" -o json 2>$null | ConvertFrom-Json
if ($pg) {
    $msg = "PG   eq-tech-pg     $($pg.state)  $($pg.sku)"
    if ($pg.state -eq "Ready") { OK $msg; Tally "OK" } else { WARN $msg; Tally "WARN" }
} else { FAIL "PG   eq-tech-pg     unreachable"; Tally "FAIL" }

# ACR
$acr = az acr show --resource-group $RG --name eqtechacr --query "sku.name" -o tsv 2>$null
if ($acr) { OK "ACR  eqtechacr      $acr"; Tally "OK" } else { FAIL "ACR  eqtechacr      unreachable"; Tally "FAIL" }

# Key Vault
$kv = az keyvault show --resource-group $RG --name eq-tech-kv --query "properties.sku.name" -o tsv 2>$null
if ($kv) { OK "KV   eq-tech-kv     $kv"; Tally "OK" } else { FAIL "KV   eq-tech-kv     unreachable"; Tally "FAIL" }

# Dev VM
$vm = az vm show --resource-group $RG --name eq-tech-devbox --show-details `
    --query powerState -o tsv 2>$null
$vmIP = az vm show --resource-group $RG --name eq-tech-devbox `
    --show-details --query publicIps -o tsv 2>$null
if ($vm -eq "VM running") {
    OK  "VM   eq-tech-devbox  Running  $vmIP  (ssh devadmin@$vmIP)"; Tally "OK"
} elseif ($vm) {
    WARN "VM   eq-tech-devbox  $vm"; Tally "WARN"
} else {
    INFO "VM   eq-tech-devbox  not provisioned"
}

# ── 2. Kubernetes Workloads ────────────────────────────────────────────────────
HEAD "2. KUBERNETES WORKLOADS"

$podLines = kubectl get pods --all-namespaces --no-headers 2>$null
if (-not $podLines) { FAIL "kubectl unavailable or cluster unreachable"; Tally "FAIL" }
else {
    # Get LB IP
    $LB_IP = kubectl get svc -n ingress-nginx ingress-nginx-controller `
        --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
    if ($LB_IP) { OK "NGINX Ingress LB IP: $LB_IP" } else { WARN "NGINX Ingress LB IP: not assigned yet" }

    Write-Host ""
    Write-Host ("  {0,-20} {1,-44} {2,-7} {3}" -f "NAMESPACE","POD","READY","STATUS") -ForegroundColor DarkGray

    $watchNS = @("dev-airflow","uat-airflow","prod-airflow","auth","dev-apps","uat-apps","prod-apps","ingress-nginx")

    foreach ($line in $podLines) {
        $parts = $line -split '\s+', 6
        if ($parts.Count -lt 5) { continue }
        $ns, $pod, $ready, $status = $parts[0], $parts[1], $parts[2], $parts[3]
        if ($watchNS -notcontains $ns) { continue }
        # truncate pod name
        $podShort = if ($pod.Length -gt 44) { $pod.Substring(0,41) + "..." } else { $pod }
        $line2 = "  {0,-20} {1,-44} {2,-7} {3}" -f $ns, $podShort, $ready, $status
        if ($status -eq "Running") { Write-Host $line2 -ForegroundColor Green; Tally "OK" }
        elseif ($status -in @("Pending","ContainerCreating","PodInitializing")) { Write-Host $line2 -ForegroundColor Yellow; Tally "WARN" }
        else { Write-Host $line2 -ForegroundColor Red; Tally "FAIL" }
    }
}

# ── 3. HTTP Endpoints ──────────────────────────────────────────────────────────
HEAD "3. HTTP ENDPOINTS"

if (-not $LB_IP) {
    WARN "LB IP unknown -- skipping endpoint checks"
} else {
    $envs = @(
        @{ name="dev";  host="dev.eq-tech.$LB_IP.nip.io"  }
        @{ name="uat";  host="uat.eq-tech.$LB_IP.nip.io"  }
        @{ name="prod"; host="eq-tech.$LB_IP.nip.io"       }
    )

    $services = @(
        @{ name="Airflow UI";  path="/airflow/health"; expect=200 }
        @{ name="OAuth2 Proxy";path="/oauth2/";        expect=302 }
        @{ name="API";         path="/api/healthz";    expect=200 }
        @{ name="Dash";        path="/dash/";          expect=200 }
        @{ name="Web UI";      path="/";               expect=200 }
    )

    Write-Host ""
    Write-Host ("  {0,-5} {1,-14} {2,-6} {3}" -f "ENV","SERVICE","CODE","URL") -ForegroundColor DarkGray

    foreach ($env in $envs) {
        foreach ($svc in $services) {
            $url = "https://$($env.host)$($svc.path)"
            $result = Test-Endpoint $url
            $codeStr = "$($result.code)"
            $row = "  {0,-5} {1,-14} {2,-6} {3}" -f $env.name, $svc.name, $codeStr, $url
            if ($result.ok -and [int]$result.code -lt 400) {
                Write-Host $row -ForegroundColor Green; Tally "OK"
            } elseif ($result.code -in @(401,403,302)) {
                # Auth redirect is expected before login
                Write-Host $row -ForegroundColor Yellow; Tally "WARN"
            } else {
                Write-Host $row -ForegroundColor Red; Tally "FAIL"
            }
        }
        Write-Host ""
    }
}

# ── 4. Summary ──────────────────────────────────────────────────────────────────
Write-Host ("=" * 72)
$total = $script:ok + $script:warn + $script:fail
$summaryColor = if ($script:fail -gt 0) { "Red" } elseif ($script:warn -gt 0) { "Yellow" } else { "Green" }
Write-Host ("  SUMMARY  OK: {0}  WARN: {1}  FAIL: {2}  (of {3} checks)" -f $script:ok, $script:warn, $script:fail, $total) -ForegroundColor $summaryColor
if ($LB_IP) {
    Write-Host ""
    Write-Host "  QUICK LINKS (nip.io access via port-forward if external TCP is blocked)" -ForegroundColor Cyan
    Write-Host "  Dev Airflow:  https://dev.eq-tech.$LB_IP.nip.io/airflow"
    Write-Host "                kubectl port-forward svc/airflow-dev-webserver 8081:8080 -n dev-airflow"
    Write-Host "  UAT Airflow:  https://uat.eq-tech.$LB_IP.nip.io/airflow"
    Write-Host "                kubectl port-forward svc/airflow-uat-webserver 8082:8080 -n uat-airflow"
    Write-Host "  Prod Airflow: https://eq-tech.$LB_IP.nip.io/airflow"
    Write-Host "                kubectl port-forward svc/airflow-prod-webserver 8083:8080 -n prod-airflow"
    Write-Host "  Dev API:      https://dev.eq-tech.$LB_IP.nip.io/api/healthz"
    Write-Host "                kubectl port-forward svc/api 8084:8000 -n dev-apps"
}
Write-Host ("=" * 72)
Write-Host ""
