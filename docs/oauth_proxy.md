Using an **OAuth2 Proxy** decoupled at the Ingress layer offloads authentication (SSO) from your applications. Once Entra ID validates the user, OAuth2 Proxy forwards claims—specifically Entra Group Object IDs—as **HTTP Headers** to your downstream pod services (Web UI, Dash apps, API microservices) for application-level RBAC.

---

### Revised Architecture Overview

```text
[ Browser / Client ]
        │
        ▼
[ Ingress Controller ] (NGINX / App Gateway)
        │ (Auth Request)
        ├──► [ OAuth2 Proxy ] ◄──OIDC / OAuth2──► [ Entra ID ]
        │         │ (200 OK + Inject Headers: X-Auth-Request-Groups)
        ▼         │
[ Pod Services ] ◄┘ (Verifies X-Auth-Request-Groups for App-Level RBAC)
  ├── React Web UI
  ├── Dash App
  └── API Microservice

```

---

### Key System Components & Setup

#### 1. Microsoft Entra ID App Registration Configuration

To pass group memberships down to OAuth2 Proxy, configure the App Registration in Entra ID:

* **Optional Claims / Token Configuration:** Add a **Groups Claim** to the ID token (select *Security Groups* or *Directory Roles*). Entra ID will emit group Object IDs (UUIDs) inside the `groups` array in the ID token.
* **Redirect URI:** Point to your ingress domain's callback path: `https://<your-domain>/oauth2/callback`.

#### 2. OAuth2 Proxy Deployment in AKS

Deploy `oauth2-proxy` using Helm. Configure it to pass user identities and group headers downstream upon successful authentication:

```yaml
# oauth2-proxy-values.yaml
config:
  provider: "oidc"
  clientID: "<ENTRA_APP_CLIENT_ID>"
  clientSecret: "<ENTRA_APP_CLIENT_SECRET>" # Managed via Azure Key Vault / Workload Identity
  oidcIssuerURL: "https://login.microsoftonline.com/<ENTRA_TENANT_ID>/v2.0"
  scope: "openid profile email"
  
  # Pass user context & groups down to the app
  pass_user_headers: true
  pass_access_token: true
  
  # Map Entra ID token claims to headers
  headers:
    - name: "X-Auth-Request-Groups"
      claim: "groups"
    - name: "X-Auth-Request-User"
      claim: "preferred_username"
    - name: "X-Auth-Request-Email"
      claim: "email"

  # Optional: Restrict cluster access globally to a specific Entra Group at the proxy level
  # allowed_groups:
  #   - "<ENTRA_GROUP_OBJECT_ID_GLOBAL_ACCESS>"

```

#### 3. Ingress Route Protection (`External-Auth` Pattern)

Configure your Kubernetes Ingress (NGINX Ingress Controller example) using annotations so every request to your UI, Dash, or API app routes through `oauth2-proxy` for authentication:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  namespace: default
  annotations:
    # Route unauthenticated requests to OAuth2 Proxy
    nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.auth.svc.cluster.local/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "https://$host/oauth2/start?rd=$escaped_request_uri"
    
    # Pass response headers injected by OAuth2 Proxy to downstream pods
    nginx.ingress.kubernetes.io/auth-response-headers: "X-Auth-Request-User, X-Auth-Request-Email, X-Auth-Request-Groups"
spec:
  rules:
    - host: app.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: dash-app-service
                port:
                  number: 8050

```

---

### App-Level Group Authorization Implementation

Once the request reaches your pod application, the app inspects the incoming `X-Auth-Request-Groups` header (which arrives as a comma-separated list of Entra Group UUIDs).

#### Dash / Python Example:

```python
from flask import Flask, request, abort
import dash
import dash_html_components as html

# Define authorized Entra ID Group Object IDs
ANALYTICS_VIEWERS_GROUP = "a1b2c3d4-0000-0000-0000-123456789abc"
ADMINS_GROUP = "e5f6g7h8-0000-0000-0000-987654321xyz"

app = dash.Dash(__name__)

@app.server.before_request
def authorize_user():
    # Ignore internal endpoints
    if request.path.startswith('/_dash') or request.path == '/healthz':
        return

    # Extract groups forwarded by OAuth2 Proxy
    user_groups = request.headers.get('X-Auth-Request-Groups', '').split(',')
    
    # Check authorization against Entra Group UUIDs
    if ANALYTICS_VIEWERS_GROUP not in user_groups and ADMINS_GROUP not in user_groups:
        # User is authenticated via SSO, but lacks authorized AD group membership
        abort(403, description="Access Denied: You do not belong to the required AD group.")

```

#### API Microservice Example (FastAPI / Node.js / C#):

* Extract `X-Auth-Request-Groups` from the header middleware.
* Implement standard Role-Based Access Control (RBAC) decorators on protected endpoints (e.g., `@require_group(ADMINS_GROUP)`).

---

### Important Edge-Case Consideration: Group Overflows

If a user belongs to **more than 150-200 Azure AD groups**, Entra ID will not include the groups array inside the ID token due to token size limits (known as a "Group Overages/Overflow" claim).

* **Mitigation Strategy:** If your organization has deep AD group hierarchies, configure the Entra App Registration to emit **Application Roles** (`roles` claim) mapped to Security Groups, or set up OAuth2 Proxy to query Microsoft Graph API on behalf of the user to fetch complete group memberships.

---