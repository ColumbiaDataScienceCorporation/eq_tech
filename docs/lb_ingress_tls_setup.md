# Replacing Port-Forwarding with LB Ingress + TLS + OAuth2 Proxy

## Current State

Port-forwarding (`kubectl port-forward`) is used for local access because three gaps prevent
the LoadBalancer ingress from working end-to-end:

| Gap | Detail |
|-----|--------|
| **No TLS** | Ingress only serves HTTP (port 80). OAuth2 proxy's `--redirect-url` and all `auth-signin` annotations use `https://`, so the login callback fails. |
| **Groups claim missing** | OAuth2 proxy is started with `--scope=openid profile email` — no `groups` scope. Entra ID does not emit group memberships, so `X-Auth-Request-Groups` is always empty and `FlaskGroupAuth` 403s every request. |
| **Single redirect URL** | One oauth2-proxy pod is deployed in the `auth` namespace with `--redirect-url` hardcoded to the dev nip.io domain. UAT and prod share the same proxy but their callback URLs are not registered. |

After completing this plan, all three environments will be accessible via the browser at:

| Env | URL |
|-----|-----|
| dev | `https://dev.eq-tech.52.185.94.105.nip.io` |
| UAT | `https://uat.eq-tech.52.185.94.105.nip.io` |
| prod | `https://eq-tech.52.185.94.105.nip.io` |

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

- [ ] cert-manager installed and `letsencrypt-prod` ClusterIssuer created
- [ ] TLS section added to `k8s/ingress/dev.yaml`, `uat.yaml`, `prod.yaml` and Airflow ingresses
- [ ] Certificates issued (`kubectl get certificate -A`)
- [ ] Entra app registration: groups claim added to ID token
- [ ] Entra app registration: all three callback URLs added to Redirect URIs
- [ ] oauth2-proxy deployed per environment (`dev-auth`, `uat-auth`, `prod-auth`) with `--oidc-groups-claim=groups`
- [ ] Old single oauth2-proxy in `auth` namespace removed
- [ ] Ingress `auth-url` / `auth-signin` updated to per-env proxies and applied
- [ ] `EQTECH_REQUIRE_GROUP_AUTH=false` env var removed from dash deployments
- [ ] Login test: browser reaches Entra login page, redirects back, Dash loads without 403
- [ ] `/api/v1/me` returns non-empty `groups` array
