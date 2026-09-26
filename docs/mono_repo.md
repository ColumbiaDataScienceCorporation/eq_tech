Replacing managed Airflow with **self-managed Apache Airflow running on Azure Kubernetes Service (AKS)** brings complete control over Airflow versions, custom Python dependencies, and task execution back into your monorepo setup.

The official Apache Airflow Helm chart will deploy and orchestrate the Airflow control plane inside your AKS cluster.

---

### Updated Architecture Mapping

| Component | Selected Technology | Deployment & Role |
| --- | --- | --- |
| **Central Workstations** | **Azure Dev Box** (or Azure VMs) | Private VNet developer workstations with pre-configured tools. |
| **CI/CD Automation** | **GitHub Actions** | Single-branch workflows with path filtering & OIDC auth. |
| **Batch Orchestration** | **Self-Managed Apache Airflow** | Deployed directly into **AKS** via the official Helm chart. |
| **Batch Database State** | **Azure Database for PostgreSQL (Flexible Server)** | Managed DB for Airflow metadata (`sql_alchemy_conn`). |
| **Kubernetes Hosting** | **Azure Kubernetes Service (AKS)** | Hosts APIs, Web UI, Dash Apps, Airflow Control Plane, & Worker Pods. |
| **Authentication & Ingress** | **OAuth2 Proxy + Entra ID** | SSO at ingress with `X-Auth-Request-Groups` header injection. |

---

### Airflow-on-AKS Architectural Pattern

To run self-managed Airflow efficiently in a Kubernetes monorepo, use the **`KubernetesExecutor`** alongside a **`git-sync` sidecar container**.

```text
[ GitHub Monorepo ] (data/airflow/dags/)
        │
        ├── (Git-Sync Sidecar periodically pulls updated DAGs)
        │
        ▼
[ AKS Cluster ]
 ├── [ Airflow Namespace ]
 │    ├── Airflow Webserver (Behind OAuth2 Proxy)
 │    ├── Airflow Scheduler (Parses DAGs, monitors tasks)
 │    └── Postgres Connection ──► [ Azure Database for PostgreSQL ]
 │
 └── [ Dynamic Worker Execution ]
      ├── Worker Pod 1 (Spin up per task -> Destroy on completion)
      └── Worker Pod 2 (Using KubernetesPodOperator for isolated container environments)

```

1. **`KubernetesExecutor`:** Each Airflow task runs in its own isolated Kubernetes Pod. This eliminates task resource contention and allows worker pods to scale to zero when no batch jobs are running.
2. **`git-sync` Strategy:** Instead of rebuilding and redeploying Docker images every time a developer updates a Python DAG, `git-sync` runs as a sidecar container in the Scheduler and Webserver pods. It continuously syncs the `data/airflow/dags/` path from your monorepo directly into Airflow volume mounts.
3. **Task Isolation (`KubernetesPodOperator`):** For heavy data jobs with conflicting Python libraries, Airflow tasks invoke dedicated Docker images built from `apps/` or `data/` subdirectories and run them as isolated pods in AKS.

---

### Helm Values Configuration (`values.yaml`)

Deploy Airflow into your AKS cluster using the official Helm chart with an external PostgreSQL metadata backend:

```yaml
# infra/helm/airflow-values.yaml
executor: "KubernetesExecutor"

# Use external production-grade PostgreSQL (Azure Flexible Server)
postgresql:
  enabled: false
data:
  metadataSecretName: "airflow-postgres-secret"

# Configure Git-Sync to automatically pull DAGs from your monorepo subpath
dags:
  gitSync:
    enabled: true
    repo: "https://github.com/your-org/your-monorepo.git"
    branch: "main"
    subPath: "data/airflow/dags"
    interval: "30s"
    credentialsSecret: "github-git-sync-ssh"

# Expose Webserver internally behind ingress / OAuth2 Proxy
webserver:
  service:
    type: ClusterIP

# Enable Ingress or let OAuth2 Proxy protect the UI
ingress:
  web:
    enabled: true
    annotations:
      nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.auth.svc.cluster.local/oauth2/auth"
      nginx.ingress.kubernetes.io/auth-signin: "https://$host/oauth2/start?rd=$escaped_request_uri"
      nginx.ingress.kubernetes.io/auth-response-headers: "X-Auth-Request-User, X-Auth-Request-Groups"
    hosts:
      - name: "airflow.yourdomain.com"

```

---

### Updated Monorepo Directory Layout

Your monorepo folder structure accommodates Airflow Helm releases alongside application code:

```text
/
├── .github/
│   └── workflows/
│       ├── infra-ci.yml                 # Terraform (AKS, Postgres, Key Vault, Dev Box)
│       ├── airflow-helm-deploy.yml      # Helm deployment for Airflow core infrastructure
│       └── api-ci.yml                   # API build & deployment
├── apps/
│   ├── api/                            # API Microservices
│   ├── ui-web/                         # Web Frontend
│   └── ui-dash/                        # Dash Applications
├── data/
│   └── airflow/                        # Self-Managed Airflow source
│       ├── dags/                       # Automatically synced by git-sync (No rebuild needed)
│       │   ├── daily_etl.py
│       │   └── risk_pipeline.py
│       ├── plugins/                    # Custom Airflow plugins
│       └── docker/                     # Optional: Custom base image for Airflow workers
└── infra/
    ├── helm/
    │   └── airflow-values/             # Environment-specific Helm value overrides
    │       ├── dev.yaml
    │       ├── uat.yaml
    │       └── prod.yaml
    └── terraform/                      # Infrastructure provisioning
        ├── main.tf
        └── environments/
            ├── dev.tfvars
            ├── uat.tfvars
            └── prod.tfvars

```

---

### Single-Branch Deployment Workflow for Self-Managed Airflow

Because DAGs are decoupled from the core infrastructure via `git-sync`, your GitHub Actions CI/CD splits into two fast paths:

1. **DAG Code Updates (`data/airflow/dags/**`):** When developers commit new Python DAGs to `main`, no container build or Helm deployment is required. `git-sync` fetches changes directly into AKS within seconds.
2. **Airflow Platform Updates (`infra/helm/**` or `data/airflow/docker/**`):** Pushes to these paths trigger the GitHub Actions workflow to run `helm upgrade --install` against the AKS cluster across `DEV`, `UAT`, and `PROD` environments using environment-specific values files.

---