1. AZURE RESOURCES
------------------------------------------------------------------------
  [OK]  AKS  eq-tech-aks   k8s 1.35  1 node(s)  Running
  [OK]  PG   eq-tech-pg     Ready  Standard_B1ms
  [OK]  ACR  eqtechacr      Basic
  [OK]  KV   eq-tech-kv     standard
  [!!]  VM   eq-tech-devbox  VM deallocated

2. KUBERNETES WORKLOADS
------------------------------------------------------------------------
  [OK]  NGINX Ingress LB IP: 52.185.94.105

  NAMESPACE            POD                                          READY   STATUS
  cert-manager         cert-manager-7dd5fd898d-jhm88                1/1     Running
  cert-manager         cert-manager-cainjector-f555478d-d6j5v       1/1     Running
  cert-manager         cert-manager-webhook-69d4696bcf-dz2bx        1/1     Running
  dev-airflow          airflow-dev-scheduler-79564778fc-w5rf4       3/3     Running
  dev-airflow          airflow-dev-statsd-576df75947-dkfhc          1/1     Running
  dev-airflow          airflow-dev-triggerer-0                      0/3     Pending
  dev-airflow          airflow-dev-webserver-5c8b9cf5bc-svcnl       1/1     Running
  dev-apps             api-68fbf8b4cd-djm9q                         1/1     Running
  dev-apps             dash-app-6df8cdb68-8km45                     1/1     Running
  dev-apps             web-ui-7567675546-f99dm                      1/1     Running
  dev-auth             oauth2-proxy-b5c8899bf-78khc                 1/1     Running
  ingress-nginx        ingress-nginx-controller-6c7cd85885-7knsp    1/1     Running
  prod-airflow         airflow-prod-scheduler-6c5777fbb7-wfcps      3/3     Running
  prod-airflow         airflow-prod-statsd-5cb4f4db98-psdp6         1/1     Running
  prod-airflow         airflow-prod-triggerer-0                     3/3     Running
  prod-airflow         airflow-prod-webserver-7f6cf6976f-ljsht      1/1     Running
  prod-apps            api-648d5cd9d5-tqfrx                         1/1     Running
  prod-apps            dash-app-cf78cb558-75g2w                     1/1     Running
  prod-apps            web-ui-647c96c4b6-kb2ct                      1/1     Running
  prod-auth            oauth2-proxy-794c7c87f8-6pwmc                1/1     Running
  uat-airflow          airflow-uat-scheduler-f8958b5cd-qqjzg        3/3     Running
  uat-airflow          airflow-uat-statsd-6cd9f9cb78-kpcpt          1/1     Running
  uat-airflow          airflow-uat-triggerer-0                      3/3     Running
  uat-airflow          airflow-uat-webserver-5f6f89459-n4q44        1/1     Running
  uat-apps             api-76448cf989-nzh4q                         1/1     Running
  uat-apps             dash-app-6cbbb87479-gfdhh                    1/1     Running
  uat-apps             web-ui-5cc87fb67d-qp8m8                      1/1     Running
  uat-auth             oauth2-proxy-666c559466-v7tn6                1/1     Running

3. HTTP ENDPOINTS
------------------------------------------------------------------------

  ENV   SERVICE        CODE   URL
  dev   Airflow UI     302    https://dev.eq-tech.52.185.94.105.nip.io/airflow/health
  dev   OAuth2 Proxy   403    https://dev.eq-tech.52.185.94.105.nip.io/oauth2/
  dev   API            302    https://dev.eq-tech.52.185.94.105.nip.io/api/healthz
  dev   Dash           302    https://dev.eq-tech.52.185.94.105.nip.io/dash/
  dev   Web UI         302    https://dev.eq-tech.52.185.94.105.nip.io/

  uat   Airflow UI     302    https://uat.eq-tech.52.185.94.105.nip.io/airflow/health
  uat   OAuth2 Proxy   403    https://uat.eq-tech.52.185.94.105.nip.io/oauth2/
  uat   API            302    https://uat.eq-tech.52.185.94.105.nip.io/api/healthz
  uat   Dash           302    https://uat.eq-tech.52.185.94.105.nip.io/dash/
  uat   Web UI         302    https://uat.eq-tech.52.185.94.105.nip.io/

  prod  Airflow UI     302    https://eq-tech.52.185.94.105.nip.io/airflow/health
  prod  OAuth2 Proxy   403    https://eq-tech.52.185.94.105.nip.io/oauth2/
  prod  API            302    https://eq-tech.52.185.94.105.nip.io/api/healthz
  prod  Dash           302    https://eq-tech.52.185.94.105.nip.io/dash/
  prod  Web UI         302    https://eq-tech.52.185.94.105.nip.io/

========================================================================
  SUMMARY  OK: 43  WARN: 5  FAIL: 0  (of 48 checks)

  URLS
  Dev:  https://dev.eq-tech.52.185.94.105.nip.io
  UAT:  https://uat.eq-tech.52.185.94.105.nip.io
  Prod: https://eq-tech.52.185.94.105.nip.io
  (Login with your Entra ID credentials)
========================================================================

Infrastructure State Summary
Paused (compute billing stopped)
Resource	State	Cost impact
AKS node aks-system-34493244-vmss instance 0	Deallocated	~$0.15/hr saved (Standard_D4pls_v5)
PostgreSQL eq-tech-pg	Stopped	Stopped but auto-restarts after 7 days
Dev VM eq-tech-devbox	Deallocated (from earlier)	Stopped
Remaining Active (minimal cost)
Resource	State	Est. cost
ACR eqtechacr	Running	~$0.17/day (Basic tier)
Key Vault eq-tech-kv	Running	~$0.03/day
Public IP 52.185.94.105	Reserved	~$0.004/hr
AKS control plane	Running (Free tier)	$0
Managed OS disks	Stored	~$0.02/day
PostgreSQL storage	Stored (even when stopped)	~$0.12/day (32 GiB)
TLS certificates	Issued (stored in k8s secrets)	$0
Total overnight cost: ~$4–5/month equivalent

