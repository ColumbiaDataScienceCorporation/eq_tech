param([switch]$KeepForwards)

$ErrorActionPreference = "SilentlyContinue"

$pfs = @(
    @{svc="airflow-dev-webserver";  ns="dev-airflow";  lp=8081; rp=8080}
    @{svc="airflow-uat-webserver";  ns="uat-airflow";  lp=8082; rp=8080}
    @{svc="airflow-prod-webserver"; ns="prod-airflow"; lp=8083; rp=8080}
    @{svc="api-service";            ns="dev-apps";     lp=8084; rp=8000}
    @{svc="api-service";            ns="uat-apps";     lp=8085; rp=8000}
    @{svc="api-service";            ns="prod-apps";    lp=8086; rp=8000}
    @{svc="dash-service";           ns="dev-apps";     lp=8087; rp=8050}
    @{svc="dash-service";           ns="uat-apps";     lp=8088; rp=8050}
    @{svc="dash-service";           ns="prod-apps";    lp=8089; rp=8050}
    @{svc="web-service";            ns="dev-apps";     lp=8090; rp=80}
    @{svc="web-service";            ns="uat-apps";     lp=8091; rp=80}
    @{svc="web-service";            ns="prod-apps";    lp=8092; rp=80}
)

$checks = @(
    @{label="Airflow dev  "; url="http://localhost:8081/airflow/health"}
    @{label="Airflow UAT  "; url="http://localhost:8082/airflow/health"}
    @{label="Airflow prod "; url="http://localhost:8083/airflow/health"}
    @{label="API     dev  "; url="http://localhost:8084/healthz"}
    @{label="API     UAT  "; url="http://localhost:8085/healthz"}
    @{label="API     prod "; url="http://localhost:8086/healthz"}
    @{label="Dash    dev  "; url="http://localhost:8087/"}
    @{label="Dash    UAT  "; url="http://localhost:8088/"}
    @{label="Dash    prod "; url="http://localhost:8089/"}
    @{label="Web UI  dev  "; url="http://localhost:8090/"}
    @{label="Web UI  UAT  "; url="http://localhost:8091/"}
    @{label="Web UI  prod "; url="http://localhost:8092/"}
)

# Start background port-forwards
$jobs = $pfs | ForEach-Object {
    Start-Job -ScriptBlock {
        param($s,$n,$l,$r)
        kubectl port-forward "svc/$s" "${l}:${r}" -n $n 2>$null
    } -ArgumentList $_.svc, $_.ns, $_.lp, $_.rp
}
Start-Sleep -Seconds 8

# Test each endpoint
Write-Host ""
Write-Host ("  {0,-16} {1,-5}  {2}" -f "SERVICE","CODE","BODY / NOTE")
Write-Host ("  " + "-"*65)

$ok=0; $warn=0; $fail=0
foreach ($c in $checks) {
    try {
        $r = Invoke-WebRequest -Uri $c.url -TimeoutSec 5 -MaximumRedirection 0 -ErrorAction Stop
        $code = $r.StatusCode
        $body = ($r.Content -replace '\s+',' ').Trim()
        if ($body.Length -gt 80) { $body = $body.Substring(0,80) + "..." }
        Write-Host ("  {0,-16} {1,-5}  {2}" -f $c.label,$code,$body) -ForegroundColor Green
        $ok++
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code) {
            if ($code -in 301,302,303,307,308) {
                Write-Host ("  {0,-16} {1,-5}  redirect -> OAuth2 login (expected)" -f $c.label,$code) -ForegroundColor Yellow
                $warn++
            } else {
                Write-Host ("  {0,-16} {1,-5}  HTTP error" -f $c.label,$code) -ForegroundColor Red
                $fail++
            }
        } else {
            Write-Host ("  {0,-16} ---    no response / pod Pending" -f $c.label) -ForegroundColor Red
            $fail++
        }
    }
}

Write-Host ""
Write-Host ("  SUMMARY: {0} reachable   {1} redirect (auth)   {2} unreachable" -f $ok,$warn,$fail) -ForegroundColor $(if ($fail -gt 0) {"Yellow"} else {"Green"})

if (-not $KeepForwards) { $jobs | Stop-Job | Remove-Job }
