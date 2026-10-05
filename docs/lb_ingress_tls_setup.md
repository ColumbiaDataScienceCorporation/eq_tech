# Replacing Port-Forwarding with LB Ingress + TLS + OAuth2 Proxy

## Deployment Status (as of 2026-10-04)

| Item | Status | Notes |
|------|--------|-------|
| Azure LB health probe | ✅ Fixed | Probe path changed to `/healthz`; LB now routes external traffic |
| cert-manager | ✅ Deployed | `letsencrypt-prod` ClusterIssuer in place |
| TLS certificates | ✅ All 6 issued | `dev/uat/prod-apps` + `dev/uat/prod-auth` certs `Ready: True` |
| Per-env oauth2-proxy | ✅ Running | `dev-auth`, `uat-auth`, `prod-auth` each `1/1 Running` |
| App ingresses (dev/uat/prod) | ✅ Applied | TLS + auth-url + ssl-redirect configured |
| Airflow ingresses | ✅ Patched | Per-env auth-url annotations applied directly |
| HTTPS access via LB | ✅ Working | `https://dev.eq-tech.52.185.94.105.nip.io/` → 302 to oauth2 login |
| Entra groups claim | ❌ Pending | Manual step — Azure Portal required (see Step 3) |
| Entra redirect URIs | ❌ Pending | Manual step — Azure Portal required (see Step 3) |
| Dash group auth | ❌ Bypassed | `EQTECH_REQUIRE_GROUP_AUTH=false` until groups flow; remove after Step 3 |

### Remaining manual steps (Azure Portal)

1. **Entra app registration** `d5679b41-4dec-42e2-a2bc-7a884b6da06a`:
   - **Token configuration → Add groups claim** → Security groups → tick ID → Save
   - **Authentication → Add Redirect URIs**:
     ```
     https://dev.eq-tech.52.185.94.105.nip.io/oauth2/callback
     https://uat.eq-tech.52.185.94.105.nip.io/oauth2/callback
     https://eq-tech.52.185.94.105.nip.io/oauth2/callback
     ```
2. **Remove Dash group auth bypass** (run after step 1 is done):
   ```powershell
   # Remove EQTECH_REQUIRE_GROUP_AUTH=false from k8s/apps/dash-deployment.yaml, then:
   foreach ($ns in @("dev-apps","uat-apps","prod-apps")) {
     kubectl apply -f k8s/apps/dash-deployment.yaml -n $ns
     kubectl rollout restart deployment/dash-app -n $ns
   }
   ```

---

## Background: What Was Blocking External LB Access

The Azure Load Balancer health probe used `RequestPath: /` on NodePort 31726.
NGINX ingress returns **HTTP 404** for any request where the `Host` header doesn't
match a configured ingress rule (probe sends the node's internal IP as Host).
Azure LB considers anything outside 2xx/3xx as **unhealthy** and stops routing ALL
external traffic. **The backend was unhealthy since the cluster was first deployed.**

Fix applied:
```powershell
$aksRg = az aks show -g eq-tech-rg -n eq-tech-aks --query nodeResourceGroup -o tsv
az network lb probe update -g $aksRg --lb-name kubernetes `
  --name "a841e94387bed4a6cbe7d8b171ae4ccc-TCP-80"  --path "/healthz"
az network lb probe update -g $aksRg --lb-name kubernetes `
  --name "a841e94387bed4a6cbe7d8b171ae4ccc-TCP-443" --path "/healthz"
kubectl annotate svc ingress-nginx-controller -n ingress-nginx `
  "service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path=/healthz" --overwrite
```

For future cluster deployments this is now baked into `scripts/provision-dev.ps1` via the
`controller.service.annotations` Helm set flag.

---

## Architecture After Implementation

```
Browser
  │  HTTPS
  ▼
NGINX Ingress (LB 52.185.94.105:443)
  │  nginx.ingress.kubernetes.io/auth-url
  ▼
oauth2-proxy-<env>  ──OIDC──►  Entra ID
  │  200 OK + injects:
  │    X-Auth-Request-User
  │    X-Auth-Request-Email
  │    X-Auth-Request-Groups   ← Entra group Object IDs
  ▼
App pod (web-service / dash-service / api-service)
  └─ FlaskGroupAuth / require_groups reads X-Auth-Request-Groups
```

---

## Step 1 — Install cert-manager

cert-manager issues and renews TLS certificates automatically from Let's Encrypt.
nip.io domains support HTTP-01 ACME challenges, so no DNS API access is required.

```powershell
# Install cert-manager CRDs and controller
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Wait for webhook to be ready before creating issuers
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s
```

Create `k8s/ingress/cluster-issuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@eq-tech.com          # replace with a real address for expiry alerts
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

```powershell
kubectl apply -f k8s/ingress/cluster-issuer.yaml
# Verify
kubectl get clusterissuer letsencrypt-prod
```

---

## Step 2 — Add TLS to the Ingress manifests

Update each environment's ingress YAML to request a certificate from cert-manager and
redirect HTTP → HTTPS.

**`k8s/ingress/dev.yaml`** (add the `tls` section and two annotations):

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.dev-auth.svc.cluster.local:4180/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "https://dev.eq-tech.52.185.94.105.nip.io/oauth2/start?rd=$escaped_request_uri"
    nginx.ingress.kubernetes.io/auth-response-headers: "X-Auth-Request-User, X-Auth-Request-Email, X-Auth-Request-Groups"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - dev.eq-tech.52.185.94.105.nip.io
      secretName: dev-eq-tech-tls
  rules: ...   # unchanged
```

Repeat for `uat.yaml` (host `uat.eq-tech.52.185.94.105.nip.io`, secret `uat-eq-tech-tls`)
and `prod.yaml` (host `eq-tech.52.185.94.105.nip.io`, secret `prod-eq-tech-tls`).

> **Note:** cert-manager watches for the `cert-manager.io/cluster-issuer` annotation, obtains
> a certificate via HTTP-01 challenge through the NGINX ingress, and stores it in the named
> secret. The ingress controller picks it up automatically.

Also add TLS to the Airflow ingresses in `dev-airflow`, `uat-airflow`, `prod-airflow` namespaces
following the same pattern.

Apply and verify:

```powershell
kubectl apply -f k8s/ingress/dev.yaml -n dev-apps
kubectl apply -f k8s/ingress/uat.yaml -n uat-apps
kubectl apply -f k8s/ingress/prod.yaml -n prod-apps

# Watch cert issuance (takes ~60 s per cert)
kubectl get certificate -A -w
```

---

## Step 3 — Configure Entra ID to emit group claims

The Entra app registration (`d5679b41-4dec-42e2-a2bc-7a884b6da06a`) must be told to include
group Object IDs in the ID token.

1. Open **Azure Portal → Entra ID → App registrations → eq_tech → Token configuration**.
2. Click **Add groups claim** → select **Security groups** → tick **ID** → Save.
3. Under **Authentication**, add all three callback URLs to **Redirect URIs**:
   ```
   https://dev.eq-tech.52.185.94.105.nip.io/oauth2/callback
   https://uat.eq-tech.52.185.94.105.nip.io/oauth2/callback
   https://eq-tech.52.185.94.105.nip.io/oauth2/callback
   ```
4. Save.

After this the ID token will contain a `groups` array of group Object IDs, which oauth2-proxy
will forward as `X-Auth-Request-Groups`.

---

## Step 4 — Deploy one oauth2-proxy per environment

The current setup has a single proxy in the `auth` namespace with the dev redirect URL.
Replace it with three environment-scoped deployments, one per namespace (`dev-auth`,
`uat-auth`, `prod-auth`), each with the correct `--redirect-url`.

### 4a. Create per-environment oauth2-proxy secrets

The client-id and client-secret are the same for all three (same Entra app registration).
Copy the existing secret into the new namespaces:

```powershell
foreach ($env in @("dev","uat","prod")) {
  $ns = "$env-auth"
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -

  # Copy client credentials from existing auth namespace
  $clientId     = kubectl get secret oauth2-proxy -n auth -o jsonpath="{.data.client-id}"
  $clientSecret = kubectl get secret oauth2-proxy -n auth -o jsonpath="{.data.client-secret}"
  $cookieSecret = kubectl get secret oauth2-proxy -n auth -o jsonpath="{.data.cookie-secret}"

  kubectl create secret generic oauth2-proxy `
    --namespace $ns `
    --from-literal=client-id=$(     [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($clientId))) `
    --from-literal=client-secret=$( [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($clientSecret))) `
    --from-literal=cookie-secret=$(  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cookieSecret))) `
    --dry-run=client -o yaml | kubectl apply -f -
}
```

### 4b. Create `k8s/auth/oauth2-proxy-values.yaml` (Helm values template)

```yaml
# k8s/auth/oauth2-proxy-values.yaml
# Deploy once per environment; substitute ENV and HOST placeholders.
config:
  existingSecret: oauth2-proxy

extraArgs:
  provider: oidc
  oidc-issuer-url: "https://login.microsoftonline.com/e5e33b11-e89c-466a-bf06-e94151676845/v2.0"
  redirect-url: "https://${HOST}/oauth2/callback"      # overridden per env (see 4c)
  scope: "openid profile email"
  email-domain: "*"
  pass-user-headers: "true"
  pass-access-token: "true"
  set-xauthrequest: "true"
  upstream: "file:///dev/null"
  # Forward the groups claim as the X-Auth-Request-Groups header
  oidc-groups-claim: "groups"

# Expose via ClusterIP; the ingress /oauth2 path routes to this service
service:
  type: ClusterIP
  port: 4180

ingress:
  enabled: true
  ingressClassName: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
  hosts:
    - host: "${HOST}"
      paths:
        - path: /oauth2
          pathType: Prefix
  tls:
    - secretName: "${ENV}-oauth2-tls"
      hosts:
        - "${HOST}"
```

### 4c. Deploy with Helm

```powershell
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests
helm repo update

$envMap = @{
  dev  = "dev.eq-tech.52.185.94.105.nip.io"
  uat  = "uat.eq-tech.52.185.94.105.nip.io"
  prod = "eq-tech.52.185.94.105.nip.io"
}

foreach ($env in $envMap.Keys) {
  $host = $envMap[$env]
  $ns   = "$env-auth"

  helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy `
    --namespace $ns `
    --values k8s/auth/oauth2-proxy-values.yaml `
    --set "extraArgs.redirect-url=https://$host/oauth2/callback" `
    --set "ingress.hosts[0].host=$host" `
    --set "ingress.tls[0].hosts[0]=$host" `
    --set "ingress.tls[0].secretName=$env-oauth2-tls" `
    --wait
}
```

### 4d. Remove the old single proxy

```powershell
helm uninstall oauth2-proxy -n auth   # or kubectl delete deployment oauth2-proxy -n auth
```

---

## Step 5 — Update ingress `auth-url` to point to per-env proxies

Each ingress currently points to `oauth2-proxy.auth.svc.cluster.local`. Update each to use the
env-scoped proxy:

```yaml
# dev.yaml
nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.dev-auth.svc.cluster.local:4180/oauth2/auth"
nginx.ingress.kubernetes.io/auth-signin: "https://dev.eq-tech.52.185.94.105.nip.io/oauth2/start?rd=$escaped_request_uri"

# uat.yaml
nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.uat-auth.svc.cluster.local:4180/oauth2/auth"
nginx.ingress.kubernetes.io/auth-signin: "https://uat.eq-tech.52.185.94.105.nip.io/oauth2/start?rd=$escaped_request_uri"

# prod.yaml
nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.prod-auth.svc.cluster.local:4180/oauth2/auth"
nginx.ingress.kubernetes.io/auth-signin: "https://eq-tech.52.185.94.105.nip.io/oauth2/start?rd=$escaped_request_uri"
```

```powershell
kubectl apply -f k8s/ingress/dev.yaml  -n dev-apps
kubectl apply -f k8s/ingress/uat.yaml  -n uat-apps
kubectl apply -f k8s/ingress/prod.yaml -n prod-apps
```

---

## Step 6 — Re-enable group auth in Dash

Once `X-Auth-Request-Groups` is populated correctly, remove the bypass:

In `k8s/apps/dash-deployment.yaml` delete the env override:

```yaml
# Remove this block:
env:
  - name: EQTECH_REQUIRE_GROUP_AUTH
    value: "false"
```

Apply to all namespaces and roll out:

```powershell
foreach ($ns in @("dev-apps","uat-apps","prod-apps")) {
  kubectl apply -f k8s/apps/dash-deployment.yaml -n $ns
  kubectl rollout restart deployment/dash-app -n $ns
}
```

Also revert the `require_group_auth` default or leave it as-is (`True`) — the env var no longer
overrides it so the flag naturally returns to enforcing groups.

---

## Step 7 — Smoke-test via LB

```powershell
# Should redirect to Entra login
Invoke-WebRequest https://dev.eq-tech.52.185.94.105.nip.io -UseBasicParsing

# After login in a browser, verify group header is forwarded
# Open https://dev.eq-tech.52.185.94.105.nip.io/api/v1/me
# Expected: { user, email, groups: ["e5027eb5-...", ...] }
```

---

## Rollback

If any step causes issues, port-forwarding can be restored immediately:

```powershell
.\scripts\port-forward.ps1
```

No application code changes are needed to fall back — the `require_group_auth` env var in
the dash deployment is the only toggle that needs reverting.

---

## Summary Checklist

- [x] Azure LB health probe fixed (`/healthz`) — **was root cause of all external access failures**
- [x] cert-manager installed and `letsencrypt-prod` ClusterIssuer created
- [x] TLS section added to `k8s/ingress/dev.yaml`, `uat.yaml`, `prod.yaml` and Airflow ingresses
- [x] Certificates issued (`kubectl get certificate -A` — all `Ready: True`)
- [x] oauth2-proxy deployed per environment (`dev-auth`, `uat-auth`, `prod-auth`) with `--oidc-groups-claim=groups`
- [x] Old single oauth2-proxy in `auth` namespace removed
- [x] Ingress `auth-url` / `auth-signin` updated to per-env proxies and applied
- [x] HTTPS reachable from internet (`https://dev.eq-tech.52.185.94.105.nip.io/` → oauth2 login)
- [ ] **Entra app registration: groups claim added to ID token** ← do this next
- [ ] **Entra app registration: all three callback URLs added to Redirect URIs** ← do this next
- [ ] `EQTECH_REQUIRE_GROUP_AUTH=false` env var removed from dash deployments (do after above)
- [ ] Login test: browser reaches Entra login page, redirects back, Dash loads without 403
- [ ] `/api/v1/me` returns non-empty `groups` array

---

## Troubleshooting: Azure LB Floating IP Not Delivering VIP Traffic

### Diagnosis

After deploying cert-manager and per-env oauth2-proxy, TLS certificate issuance via
Let's Encrypt HTTP-01 fails with:

```
Timeout during connect (likely firewall problem)
52.185.94.105: Fetching http://dev.eq-tech.52.185.94.105.nip.io/.well-known/acme-challenge/...
```

Direct TCP tests from any internet-connected host also fail for both ports:

```powershell
Test-NetConnection -ComputerName 52.185.94.105 -Port 80  # False
Test-NetConnection -ComputerName 52.185.94.105 -Port 443 # False
```

### Root Cause

**The Azure LB health probe was returning HTTP 404 from NGINX since day 1**, causing
the LB to permanently mark the backend as unhealthy and stop routing all external traffic.

The AKS cloud-controller creates the LB health probe with `RequestPath: /`. NGINX ingress
responds to `/` with 404 (no ingress rule matches the node's internal IP as Host). Azure LB
considers anything outside 2xx/3xx as unhealthy, so the backend was always unhealthy.

Confirmed diagnosis:
```powershell
# 404 = backend unhealthy = LB drops all external traffic
kubectl run probe-test --image=busybox --restart=Never -- \
  sh -c "wget -q -S -O /dev/null http://10.224.0.4:31726/ 2>&1"
# → HTTP/1.1 404 Not Found

# 200 = NGINX's own healthz endpoint
kubectl run probe-test --image=busybox --restart=Never -- \
  sh -c "wget -q -S -O /dev/null http://10.224.0.4:31726/healthz 2>&1"
# → HTTP/1.1 200 OK
```

All other symptoms (zero iptables packets for 52.185.94.105, TCP timeouts from internet,
NSG rules appearing correct) were downstream effects of the unhealthy backend.

### Fix (RESOLVED)

Update both Azure LB health probes to use `/healthz` (returns 200 from NGINX ingress):

```powershell
$aksRg = az aks show -g eq-tech-rg -n eq-tech-aks --query nodeResourceGroup -o tsv
az network lb probe update -g $aksRg --lb-name kubernetes \
  --name "a841e94387bed4a6cbe7d8b171ae4ccc-TCP-80"  --path "/healthz"
az network lb probe update -g $aksRg --lb-name kubernetes \
  --name "a841e94387bed4a6cbe7d8b171ae4ccc-TCP-443" --path "/healthz"
```

Annotate the Kubernetes service so this survives cloud-controller reconciliation:

```powershell
kubectl annotate svc ingress-nginx-controller -n ingress-nginx \
  "service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path=/healthz" \
  --overwrite
```

After this fix:
- `Test-NetConnection 52.185.94.105 -Port 80` → `True`
- `Test-NetConnection 52.185.94.105 -Port 443` → `True`
- All 6 TLS certificates issued (`kubectl get certificate -A` → all `Ready: True`)
- `https://dev.eq-tech.52.185.94.105.nip.io/` → 302 redirect to oauth2 login

### Permanent fix in `k8s/ingress-nginx-values.yaml`

Add to the ingress-nginx Helm values to make this permanent across future redeployments:

```yaml
controller:
  service:
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: "/healthz"
```

### Fix Sequence (try in order, stop at first success)

After each fix, test with:

```powershell
Test-NetConnection -ComputerName 52.185.94.105 -Port 80
# Then trigger fresh certs:
kubectl delete certificate --all -n dev-apps
kubectl get certificate -n dev-apps -w
```

---

#### Fix A — Force cloud-controller-manager to reconcile the service

Add `spec.loadBalancerIP` to pin the existing IP. The cloud controller detects the
change, re-processes the service, and refreshes the Azure LB / NIC Floating IP config.

```powershell
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type merge -p "{""spec"":{""loadBalancerIP"":""52.185.94.105""}}"
# Wait 60s for cloud controller to process
Start-Sleep -Seconds 60
Test-NetConnection -ComputerName 52.185.94.105 -Port 80
```

---

#### Fix B — Annotate the service to force AKS LB health-probe rule refresh

AKS cloud-controller watches for annotation changes and re-reconciles on any update.

```powershell
kubectl annotate svc ingress-nginx-controller -n ingress-nginx `
  service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path="/" --overwrite
Start-Sleep -Seconds 60
Test-NetConnection -ComputerName 52.185.94.105 -Port 80
```

---

#### Fix C — Cordon, drain, and uncordon the AKS node

Forces AKS to re-register the node with the Azure LB backend pool, triggering a full
NIC configuration refresh.

```powershell
$node = kubectl get node -o jsonpath="{.items[0].metadata.name}"
kubectl cordon $node
kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force --timeout=120s
kubectl uncordon $node
# Wait for node to become Ready and pods to reschedule
kubectl get nodes -w
Start-Sleep -Seconds 90
Test-NetConnection -ComputerName 52.185.94.105 -Port 80
```

> This causes a brief service interruption (~2-3 minutes) while pods reschedule.

---

#### Fix D — Delete and recreate the ingress-nginx LoadBalancer service

The most disruptive but most reliable fix. Preserves the static IP via `loadBalancerIP`.

```powershell
# 1. Export the current service definition
kubectl get svc ingress-nginx-controller -n ingress-nginx -o yaml > /tmp/nginx-svc-backup.yaml

# 2. Delete the service (Azure LB rules are removed, but the static Public IP remains)
kubectl delete svc ingress-nginx-controller -n ingress-nginx

# 3. Recreate with loadBalancerIP to reclaim the same IP
kubectl patch svc ingress-nginx-controller -n ingress-nginx --dry-run=client # verify gone
helm upgrade ingress-nginx ingress-nginx/ingress-nginx `
  --namespace ingress-nginx --reuse-values `
  --set "controller.service.loadBalancerIP=52.185.94.105" `
  --wait --timeout 120s

Test-NetConnection -ComputerName 52.185.94.105 -Port 80
```

---

#### Fix E — AKS scale cycle (last resort)

Scaling to 0 and back forces Azure to provision a fresh VMSS instance and fully
re-configure its NIC for the LB, including Floating IP rules.

```powershell
# Scale to 0 (pauses all workloads)
az aks nodepool scale -g eq-tech-rg --cluster-name eq-tech-aks --name system --node-count 0

# Wait for scale-down to complete
az aks nodepool show -g eq-tech-rg --cluster-name eq-tech-aks --name system --query provisioningState -o tsv

# Scale back to 1 -- Azure provisions a new VM and configures its NIC
az aks nodepool scale -g eq-tech-rg --cluster-name eq-tech-aks --name system --node-count 1

# Wait for node Ready
kubectl get nodes -w

# Refresh kubectl credentials
az aks get-credentials -g eq-tech-rg -n eq-tech-aks --overwrite-existing

Test-NetConnection -ComputerName 52.185.94.105 -Port 80
```

> All pods will be evicted and must reschedule. Run `scripts/resume-infra.ps1` after
> which handles the AKS scale-up and kubectl credential refresh automatically.
