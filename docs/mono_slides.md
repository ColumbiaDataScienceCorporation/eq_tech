# Modern Financial Engineering on Azure AKS
## A Mono-Repo, AI-Ready, Cloud-Native Architecture

---

## Slide 1 — The Problem We Solved

**Before: Fragmented Infrastructure (Azure Repos + Azure DevOps)**

- Teams using Azure Repos — a stable but maintenance-mode platform receiving no major new features
- Multiple disconnected repositories — no shared code, no shared standards
- CI/CD pipelines exist but are tightly coupled to Azure DevOps — no portability, no OIDC, credentials stored as pipeline variables
- Secrets scattered across machines and developer laptops
- No consistent environments between dev, UAT, and production
- Data pipelines, APIs, and dashboards maintained by separate teams with no shared contracts
- No native AI assistance — Azure Repos lacks built-in Copilot integration
- New developers took weeks to onboard

**After: One Repo, One Truth, Three Environments — on GitHub Enterprise**

- Single GitHub Enterprise repo governs everything: code, infrastructure, config, CI/CD
- Push to a branch → environment is updated automatically
- All credentials live in Azure Key Vault — no secrets ever touch a laptop
- Dev, UAT, and prod are structurally identical — what works in dev ships to prod
- GitHub Copilot natively integrated — AI assistance across every file in context

---

## Slide 2 — Why GitHub Enterprise over Azure Repos?

**Current state:** Most teams use Azure Repos + Azure Pipelines (Azure DevOps)

**The strategic choice:**

| Dimension | GitHub Enterprise | Azure Repos |
|-----------|-------------------|-------------|
| Microsoft investment | **Primary innovation engine** — AI, security, velocity | Maintenance mode — security patches only |
| AI assistance | **Native GitHub Copilot** — full repo context | No native AI; requires extensions |
| Security | **GHAS** — secret scanning, dependency alerts, code scanning | Basic branch policies and PR approvals |
| Cloud portability | **Cloud-agnostic** — runs on Azure, AWS, GCP, on-prem | Locked into Azure DevOps ecosystem |
| CI/CD | **GitHub Actions** — OIDC federation, 50K+ marketplace actions | Azure Pipelines — tightly coupled to Azure |
| Talent market | Overwhelmingly preferred by quant/data engineers | Familiar to traditional enterprise teams |
| ADF/Synapse | Requires GitHub App setup | Native one-click visual integration |

**Why GitHub wins for a quant platform:**

1. **Portability** — Not locked into Azure; runners can execute inside AWS, GCP, or on-prem without re-architecture
2. **Protecting alpha models** — GHAS secret scanning blocks accidental credential commits before they leave the developer's machine
3. **AI velocity** — GitHub Copilot with full mono-repo context accelerates quant research, DAG authoring, and infrastructure work
4. **Talent attraction** — Top quant analysts and engineers overwhelmingly prefer GitHub over Azure DevOps

> **The only advantage Azure Repos retains:** Visual drag-and-drop Azure Data Factory / Synapse pipeline authoring with one-click Git commit.  
> If your engineers write code rather than drag pipelines, GitHub wins.

---

## Slide 3 — Architecture Overview (Infrastructure Perspective)

```mermaid
graph TB
    Browser[Browser / API Client]
    GitHub[GitHub Enterprise]
    LE[Let's Encrypt ACME]

    subgraph Ingress["Ingress Layer (AKS)"]
        NGINX[NGINX LB: 52.185.94.105]
        CM[cert-manager]
        PROXY[oauth2-proxy dev/uat/prod]
    end

    subgraph Namespaces["App Namespaces — dev / uat / prod"]
        AIRFLOW[Airflow scheduler+webserver+triggerer]
        API[FastAPI]
        DASH[Dash]
        WEB[Web UI]
    end

    subgraph AzureServices["Azure Services"]
        ACR[Container Registry]
        PG[PostgreSQL]
        KV[Key Vault]
        ENTRA[Entra ID]
        DEVVM[Dev Server]
    end

    Browser -->|HTTPS| NGINX
    NGINX --> PROXY -->|OIDC| ENTRA
    NGINX --> AIRFLOW & API & DASH & WEB
    CM -->|HTTP-01| LE
    GitHub -->|OIDC push| ACR
    ACR --> Namespaces
    API & AIRFLOW --> PG
    KV -.->|secrets| Namespaces
    DEVVM -.->|kubectl| Namespaces
```

---

## Slide 4 — Architecture Overview (App Developer Perspective)

```mermaid
graph TB
    subgraph Repo["eq_tech mono-repo"]
        LIB["lib/\nconfig · auth · db · logging · portfolio"]
        APPS["apps/\napi · ui-dash · ui-web"]
        DAGS["data/airflow/dags/\ndaily_etl_dag.py"]
        K8S["k8s/ and infra/helm/"]
        CI[".github/workflows/"]
    end

    subgraph Pipeline["CI/CD Pipeline"]
        LINT["1. Lint + 22 Tests"]
        BUILD["2. Multi-arch Docker Build\nlinux/amd64 + linux/arm64"]
        DEPLOY["3. kubectl apply\nper-env namespace"]
    end

    subgraph Envs["Live Environments"]
        DEV_ENV["dev environment"]
        UAT_ENV["uat environment"]
        PROD_ENV["prod environment"]
    end

    LIB -->|imported by| APPS
    LIB -->|imported by| DAGS
    CI -->|triggers| LINT
    LINT --> BUILD --> DEPLOY
    DEPLOY -->|develop branch| DEV_ENV
    DEPLOY -->|uat branch| UAT_ENV
    DEPLOY -->|main branch| PROD_ENV
```

---

## Slide 5 — Why Mono-Repo?

**One repository contains everything the platform needs**

| Layer | Location in repo |
|-------|-----------------|
| Shared libraries | `lib/` |
| Applications | `apps/api/`, `apps/ui-dash/`, `apps/ui-web/` |
| DAGs | `data/airflow/dags/` |
| Kubernetes manifests | `k8s/` |
| Helm values (per env) | `infra/helm/airflow-values/` |
| CI/CD workflows | `.github/workflows/` |
| Scripts | `scripts/` |
| Tests | `tests/` |

**Key benefits**

- **Atomic changes**: A single PR can change the lib, the API that uses it, and the DAG that calls the API together
- **Unified versioning**: One git SHA describes the entire system state
- **No version hell**: `lib/` is always compatible with `apps/` because they share a commit
- **Single test suite**: 22 tests cover all layers — run with one command
- **Discoverability**: Any developer can find any piece of the system without hunting across repos

---

## Slide 6 — Shared Library Architecture

```mermaid
graph TD
    subgraph lib["lib/ — shared by all apps and DAGs"]
        CONFIG["lib/config/settings.py\nPydantic Settings · Entra IDs\nPostgres URL · Key Vault URL\nenv-aware (dev/uat/prod)"]
        AUTH["lib/auth/groups.py\nFlaskGroupAuth · require_groups()\nX-Auth-Request-Groups parsing\nFastAPI dependency injection"]
        DB["lib/db/\npostgres.py — SQLAlchemy sessions\nmodels.py — PortfolioPosition\nhealth_check()"]
        LOG["lib/logging/structured.py\nStructuredLogger wrapper\n*args/**kwargs support\nJSON-compatible output"]
        PORTFOLIO["lib/portfolio/metrics.py\nsummarise_positions()\nP&L · market value · weights"]
    end

    CONFIG --> AUTH
    CONFIG --> DB
    CONFIG --> LOG

    subgraph apps["Applications"]
        API["apps/api/main.py\nFastAPI"]
        DASH["apps/ui-dash/app.py\nPlotly Dash"]
        DAG["data/airflow/dags/\ndaily_etl_dag.py"]
    end

    CONFIG --> API & DASH & DAG
    AUTH --> API & DASH
    DB --> API & DAG
    LOG --> API & DASH & DAG
    PORTFOLIO --> API
```

**Write once, use everywhere:**
A bug fix in `lib/auth/groups.py` is automatically applied to both the API and the Dash app in the same commit. No sync required.

---

## Slide 7 — Branch-Based SDLC

```mermaid
gitGraph
   commit id: "initial"
   branch develop
   checkout develop
   branch feature/new-dag
   checkout feature/new-dag
   commit id: "add DAG logic"
   commit id: "add tests"
   checkout develop
   merge feature/new-dag id: "merge feature"
   commit id: "deploy to DEV"
   branch uat
   checkout uat
   merge develop id: "promote to UAT"
   commit id: "deploy to UAT"
   checkout main
   merge uat id: "promote to PROD"
   commit id: "deploy to PROD"
```

**Each branch maps to an environment:**

| Branch | Environment | Trigger |
|--------|-------------|---------|
| `develop` | **dev** | Any merge to develop |
| `uat` | **UAT** | Promote develop → uat |
| `main` | **prod** | Promote uat → main |

**Branch protection rules ensure:**
- PRs required with at least 1 reviewer
- All CI checks must pass before merge
- No direct pushes to `main` or `uat`

---

## Slide 8 — CI/CD Pipeline Detail

```mermaid
flowchart TD
    PUSH[Push / PR to develop/uat/main]

    PUSH --> LINT[lint-test.yml\n22 pytest tests\nruff linting\nPython 3.12]

    LINT -->|pass| APPS[apps-ci.yml\nMulti-arch Docker build\nlinux/amd64 + linux/arm64\nOIDC → ACR push]

    APPS -->|develop| DEPLOY_DEV[kubectl apply\ndev-apps namespace]
    APPS -->|uat| DEPLOY_UAT[kubectl apply\nuat-apps namespace]
    APPS -->|main| DEPLOY_PROD[kubectl apply\nprod-apps namespace\n+ push :latest tag]

    PUSH --> AIRFLOW[airflow-helm-deploy.yml\nhelm upgrade per branch env\nwith rollback-on-failure]

    PUSH --> INFRA[infra-ci.yml\nTerraform plan/apply\nfor infra changes]

    style LINT fill:#2d8a4e,color:#fff
    style APPS fill:#1a6b9a,color:#fff
    style DEPLOY_DEV fill:#6b3fa0,color:#fff
    style DEPLOY_UAT fill:#a07030,color:#fff
    style DEPLOY_PROD fill:#a03030,color:#fff
```

**No secrets in CI:** GitHub Actions uses OIDC federation with Azure — no stored credentials, no expiry, no rotation needed.

---

## Slide 9 — Centralized, Safe Configuration Management

```mermaid
graph LR
    subgraph Sources["Config Sources (priority order)"]
        ENV_VAR[Environment Variables\ninjected by Kubernetes]
        DOTENV[.env file\non dev server only]
        DEFAULT[Pydantic defaults\nin settings.py]
    end

    subgraph Settings["lib/config/Settings"]
        POSTGRES[postgres_host / port / db\npostgres_password: SecretStr]
        AZURE[azure_tenant_id\nazure_key_vault_url]
        GROUPS[analysts_group_id\nadmins_group_id\nrisk_group_id]
        ENV[environment: dev/uat/prod\nlog_level: auto-resolved]
    end

    subgraph K8s["Kubernetes Secrets / ConfigMaps"]
        CM[eq-tech-groups ConfigMap\ngroup Object IDs per namespace]
        SECRET[eq-tech-secrets Secret\nEQTECH_POSTGRES_PASSWORD]
        OAUTH[oauth2-proxy Secret\nclient-id · client-secret · cookie-secret]
    end

    subgraph KV["Azure Key Vault"]
        KV_PG[pg-admin-password]
        KV_OAUTH[oauth2-proxy credentials]
    end

    ENV_VAR --> Settings
    DOTENV --> Settings
    DEFAULT --> Settings
    K8s --> ENV_VAR
    KV --> K8s
```

**Key principles:**
- `SecretStr` type — secrets never appear in logs or stack traces
- Namespace isolation — dev pods only see dev secrets, prod pods only see prod secrets
- Single `get_settings()` call works identically in all three environments
- Developers never handle production credentials directly

---

## Slide 10 — Self-Hosted Airflow: The Right Choice

```mermaid
graph TB
    subgraph Why["Why Self-Hosted over Managed?"]
        COST["Cost: Managed Airflow (MWAA) = $300-500+/month\nSelf-hosted on AKS = ~$30/month"]
        CONTROL["Full control over:\n· Python packages\n· DAG git-sync branch\n· Executor config\n· Plugins and connections"]
        INTEGRATION["Deep integration:\n· Same lib/ as API and Dash\n· Same Entra SSO\n· Same PostgreSQL\n· Same Key Vault secrets"]
        PERF["ARM64 node support\nHelm-managed, versioned\nPer-environment config"]
    end

    subgraph Arch["Airflow Architecture on AKS"]
        GIT[Git Sync Sidecar\nbranch per environment]
        SCHED[Scheduler\n3 containers: scheduler + statsd + log]
        WEB[Webserver\nFlask + Gunicorn]
        TRIG[Triggerer\nasync sensor offloading]
        PG2[PostgreSQL\nmetadata DB per env]
        GIT --> SCHED
        SCHED --> WEB & TRIG & PG2
    end
```

**One deployment configuration serves three environments:**

```yaml
# dev uses develop branch DAGs
dags.gitSync.branch: "develop"

# uat uses uat branch DAGs  
dags.gitSync.branch: "uat"

# prod uses main branch DAGs
dags.gitSync.branch: "main"
```

When a DAG is promoted from develop → uat → main, the live Airflow instance picks it up automatically via git-sync. No manual DAG uploads.

---

## Slide 11 — OAuth2 + Entra SSO: Zero-Trust Access

```mermaid
sequenceDiagram
    participant B as Browser
    participant N as NGINX Ingress
    participant P as oauth2-proxy
    participant E as Entra ID
    participant A as App (API/Dash/Airflow)

    B->>N: GET /dash/ (no session)
    N->>P: auth_request /oauth2/auth
    P-->>N: 401 Unauthorized
    N-->>B: 302 → /oauth2/start
    B->>P: /oauth2/start?rd=/dash/
    P-->>B: 302 → Entra login
    B->>E: Login (jin_xin1@hotmail.com)
    E-->>B: 302 → /oauth2/callback?code=...
    B->>P: /oauth2/callback (exchange code)
    P->>E: Token exchange (OIDC)
    E-->>P: ID token + groups claim
    Note over P: Session cookie set<br/>groups: [analysts, admins, ...]
    P-->>B: 302 → /dash/
    B->>N: GET /dash/ (with session cookie)
    N->>P: auth_request /oauth2/auth
    P-->>N: 200 + X-Auth-Request-Groups: e5027eb5,...
    N->>A: Proxy request + group headers
    A->>A: FlaskGroupAuth checks groups
    A-->>B: 200 Dashboard
```

**Group-based RBAC without a single line of identity code in the apps.** The proxy injects `X-Auth-Request-Groups` and the shared `lib/auth/groups.py` enforces it.

---

## Slide 12 — The Central Dev Server

```mermaid
graph LR
    subgraph DevServer["eq-tech-devbox (Azure VM ARM64)"]
        TOOLS["Pre-installed:\n· kubectl + helm\n· az CLI\n· Python 3.12 venv\n· Docker\n· git"]
        VENV["/opt/eq-tech/venv\nAll lib/ dependencies\npip install -e .[dev]"]
        ENV_FILE[".env\nPostgres password\nGroup Object IDs\nKey Vault URL"]
        SCRIPTS["scripts/\npause/resume infra\ncheck health\ncreate secrets\nconfigure Entra"]
    end

    subgraph Benefits["Benefits"]
        B1["ARM64 native execution\n(same arch as AKS node)"]
        B2["kubectl access to all 3 envs\nDirect cluster operations"]
        B3["Reproducible environment\nNo 'works on my machine'"]
        B4["Idle auto-shutdown\ncost-controlled"]
        B5["One SSH command away\nfor any team member"]
    end

    DevServer --> Benefits

    subgraph Use_Cases["Typical Dev Server Tasks"]
        UC1[Run ad-hoc Python scripts\nagainst live Postgres]
        UC2[kubectl exec into pods\nfor live debugging]
        UC3[Trigger Airflow DAG runs\nmanually]
        UC4[Run DB migrations\nbefore deployment]
        UC5[Test lib/ changes\nagainst real Azure services]
    end
```

**Cost-aware:** The dev server auto-shuts down when idle (cron + auto-shutdown policy). `scripts/resume-devvm.ps1` brings it back on demand in ~60 seconds.

---

## Slide 13 — GitHub: The AI-Ready Backbone

```mermaid
graph TB
    subgraph GitHub_Features["GitHub Enterprise Features"]
        OIDC["OIDC Federation\nNo stored credentials\nAzure RBAC via token"]
        ACTIONS["GitHub Actions\n4 workflows\nlint · build · deploy · infra"]
        PROTECTION["Branch Protection\nPR reviews required\nCI must pass"]
        AUDIT["Audit Log\nEvery deployment\ntraced to a commit"]
    end

    subgraph AI_Integration["AI Agent Integration"]
        COPILOT["GitHub Copilot\nInline code completion\nChat + context-aware\nAgent mode with tools"]
        PR_REVIEW["AI PR Review\nAutomatic code review\nsecurity scanning\ndocumentation gaps"]
        ISSUE["Issue Intelligence\nAI-linked to PRs\nAutomatic labeling"]
        ACTIONS_AI["Actions AI debugging\nExplain failed runs\nSuggest fixes"]
    end

    subgraph Workflows["AI-Accelerated Workflows"]
        W1["Developer describes feature\nin natural language\n→ Copilot generates code"]
        W2["Agent reads repo context\n→ Proposes PR + tests\n→ Developer reviews"]
        W3["Failed CI → AI explains\nthe root cause\n→ Suggests fix"]
        W4["New engineer onboards\nAsk Copilot about\nany file or system"]
    end

    GitHub_Features --> AI_Integration
    AI_Integration --> Workflows
```

**This entire platform was built with GitHub Copilot as an AI pair programmer:** Infrastructure provisioning, CI/CD workflows, shared libraries, OAuth2 integration, TLS setup — all accelerated by AI agents that understand the full repository context.

---

## Slide 14 — Security Model

```mermaid
graph TD
    subgraph Network["Network Security"]
        LB["Azure LB - port 443 only\nPublic IP 52.185.94.105"]
        NSG["NSG Rules\nAllow Internet to LB only"]
        TLS["Let's Encrypt TLS\nauto-renewed by cert-manager"]
    end

    subgraph Identity["Identity and Access"]
        ENTRA2["Entra ID\ntenant-specific OIDC"]
        GROUPS["Security Group RBAC\nanalysts / admins / risk"]
        OIDC["OIDC Federation\nGitHub Actions to Azure"]
    end

    subgraph Secrets["Secret Management"]
        KV2["Azure Key Vault\nAll production secrets"]
        K8S_SEC["Kubernetes Secrets\nnamespace-isolated"]
        SECRET_STR["Pydantic SecretStr\nnever logged or printed"]
    end

    subgraph Runtime["Runtime Isolation"]
        NS["Kubernetes Namespaces\ndev / uat / prod isolated"]
        POD["Workload Identity\nper-namespace service accounts"]
    end

    LB --> ENTRA2
    NSG --> LB
    TLS --> LB
    ENTRA2 --> GROUPS
    ENTRA2 --> OIDC
    GROUPS --> KV2
    KV2 --> K8S_SEC
    K8S_SEC --> SECRET_STR
    K8S_SEC --> NS
    NS --> POD
```

**Defense in depth:** Every layer has its own security boundary. A compromised dev pod cannot access prod secrets. A compromised prod pod cannot SSH to the dev server.

---

## Slide 15 — Platform Endpoints Summary

**Three environments, consistent structure:**

| Path | Service | Auth |
|------|---------|------|
| `https://{env}/` | Web UI (React/Nginx) | Entra SSO |
| `https://{env}/dash/` | Plotly Dash analytics | Entra SSO + group check |
| `https://{env}/api/v1/me` | User identity | Entra SSO |
| `https://{env}/api/v1/portfolio` | Portfolio data + P&L | Entra SSO + analysts/admins group |
| `https://{env}/api/docs` | Swagger UI | Entra SSO |
| `https://{env}/airflow/` | Airflow web UI | Entra SSO |
| `https://{env}/oauth2/start` | Login entrypoint | — |

**Environment hostnames:**

| Env | Hostname |
|-----|----------|
| Dev | `dev.eq-tech.52.185.94.105.nip.io` |
| UAT | `uat.eq-tech.52.185.94.105.nip.io` |
| Prod | `eq-tech.52.185.94.105.nip.io` |

---

## Slide 16 — Developer Experience: Day in the Life

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant GH as GitHub + Copilot
    participant CI as GitHub Actions
    participant DEV as Dev Environment
    participant UAT as UAT Environment

    Dev->>GH: Create feature branch
    Dev->>GH: Ask Copilot to generate DAG skeleton
    GH-->>Dev: Generated code + docstring
    Dev->>GH: Write tests with Copilot assistance
    Dev->>GH: Push → PR opened
    GH->>CI: Run lint-test.yml (22 tests)
    CI-->>GH: ✅ All tests pass
    GH->>CI: Build + push Docker images
    CI->>DEV: Deploy to dev namespace
    Dev->>DEV: Visit https://dev.eq-tech...
    Dev->>DEV: Login with Entra ID
    DEV-->>Dev: See changes live
    Dev->>GH: PR reviewed + merged to develop
    GH->>CI: Promote to develop → auto-deploy dev
    Dev->>GH: Open PR: develop → uat
    GH->>CI: Auto-deploy to UAT
    Dev->>UAT: Validate in UAT
    Dev->>GH: Open PR: uat → main
    GH->>CI: Deploy to production
```

**Total time from idea to production: hours, not days.**

---

## Slide 17 — Operational Scripts

**Everything is scripted. Nothing requires the Azure portal.**

| Script | Purpose |
|--------|---------|
| `resume-infra.ps1` | Start AKS node + PostgreSQL + refresh kubectl |
| `pause-infra.ps1` | Stop all compute (saves ~$0.15/hr) |
| `resume-devvm.ps1` | Start dev server, print SSH command |
| `pause-devvm.ps1` | Deallocate dev server |
| `check-infra-health.ps1` | Azure resources + k8s pods + HTTP endpoints status |
| `setup-tls-oauth.ps1` | Deploy cert-manager + per-env oauth2-proxy + TLS |
| `create-pg-secrets.ps1` | Provision k8s secrets from Key Vault |
| `configure-entra-app.ps1` | Set up Entra app registration + k8s oauth2-proxy secrets |
| `port-forward.ps1` | Local dev access to all services |
| `test-endpoints.ps1` | Smoke-test all 12 service endpoints |

**Result:** Any engineer can operate the entire platform with no Azure portal access required.

---

## Slide 18 — Cost Architecture

```mermaid
pie title Monthly Infrastructure Cost (approximate)
    "AKS Node Standard_D4pls_v5" : 110
    "PostgreSQL B1ms" : 15
    "Dev VM Standard_D2pls_v6" : 35
    "ACR Basic" : 5
    "Key Vault" : 1
    "Public IPs + LB" : 5
    "Storage + Bandwidth" : 4
```

**Cost optimization built in:**
- ARM64 nodes (D4pls_v5) — 30% cheaper than equivalent x86
- PostgreSQL Flexible Server B1ms — smallest tier for dev workloads
- AKS Free tier — no control plane cost
- Idle auto-shutdown on dev server
- `pause-infra.ps1` — scales to ~$4/month during off hours (storage only)
- Single node cluster — all 3 environments share 1 node

**Estimated total: ~$175/month running / ~$4/month paused**

---

## Slide 19 — Why This Architecture Scales

**Today (single-node demo cluster):**
- 1 × ARM64 node running dev + UAT + prod simultaneously
- All services co-located with resource limits enforced
- Adequate for development and stakeholder demos

**Tomorrow (scale-out path):**

```mermaid
graph LR
    NOW["Now\n1 node\ndev+uat+prod\n$175/month"]
    -->|"Add node pool"| MEDIUM["Medium scale\n3 nodes\n1 per environment\n$400/month"]
    -->|"Separate clusters"| LARGE["Enterprise\n3 clusters\nwith SLA\n$1200/month"]

    MEDIUM -.->|"No code changes\nOnly infra/terraform\nand Helm values"| MEDIUM
```

**The application code, CI/CD workflows, and security model require zero changes to scale.** Only the Terraform variables change.

---

## Slide 20 — Key Takeaways

**The mono-repo approach delivers:**

1. **Speed** — Feature to production in hours via branch-based SDLC + automated CI/CD
2. **Safety** — Zero secrets on developer machines; Entra SSO + group RBAC enforced at the proxy
3. **Consistency** — Dev, UAT, and prod are structurally identical — bugs don't hide in environment differences
4. **Discoverability** — Every piece of the system is one `git grep` away
5. **AI-ready** — GitHub Copilot has full repository context, enabling AI-assisted development across all layers
6. **Operability** — Every operational task is a PowerShell script; no portal required
7. **Cost control** — ARM64 nodes, pause scripts, and per-environment resource limits keep costs predictable

**The platform demonstrates that financial engineering infrastructure can be:**
- **Professional** — TLS everywhere, Entra SSO, audit trails
- **Affordable** — ~$175/month for 3 full environments
- **Maintainable** — 22 automated tests, shared libraries, documented scripts
- **AI-accelerated** — Built with and for GitHub Copilot

---

## Slide 21 — Thank You

**EQ Tech Platform Stack**

| Layer | Technology |
|-------|-----------|
| Cloud | Microsoft Azure (centralus) |
| Compute | AKS (ARM64) + Azure VM |
| Container Registry | Azure Container Registry |
| Database | PostgreSQL 16 Flexible Server |
| Secret Management | Azure Key Vault |
| Identity | Entra ID + oauth2-proxy |
| Ingress | NGINX Ingress Controller + cert-manager |
| Orchestration | Apache Airflow 2.11 (Helm) |
| API | FastAPI + SQLAlchemy |
| Dashboard | Plotly Dash |
| CI/CD | GitHub Actions (OIDC) |
| IaC | Terraform |
| Language | Python 3.12 |
| Config | Pydantic Settings |
| AI Tooling | GitHub Copilot (Claude Sonnet) |

**Repository:** `github.com/ColumbiaDataScienceCorporation/eq_tech`

---

*Generated with GitHub Copilot (Claude Sonnet 4.6) — an AI agent with full repository context*
