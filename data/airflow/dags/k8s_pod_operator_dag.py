from datetime import datetime, timedelta
import os
from airflow import DAG
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from kubernetes.client import models as k8s

default_args = {
    "owner": "eq-tech",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

# Read from the env var injected by the Airflow Helm values; falls back to dev
_NAMESPACE = os.environ.get("AIRFLOW_NAMESPACE", "dev-airflow")

with DAG(
    dag_id="k8s_pod_example",
    description="Runs an isolated compute task in a dedicated Kubernetes Pod",
    schedule="@weekly",
    start_date=datetime(2024, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["kubernetes", "example"],
) as dag:

    risk_compute = KubernetesPodOperator(
        task_id="risk_compute_pod",
        name="risk-compute-pod",
        namespace=_NAMESPACE,
        # Any image from ACR or public registry can be used here
        image="python:3.11-slim",
        cmds=["python", "-c"],
        arguments=[
            "import math; "
            "portfolio = [0.02, -0.01, 0.03, -0.005, 0.015]; "
            "vol = math.sqrt(sum(r**2 for r in portfolio) / len(portfolio)); "
            "print(f'Portfolio daily volatility: {vol:.4f}')"
        ],
        resources=k8s.V1ResourceRequirements(
            requests={"cpu": "250m", "memory": "256Mi"},
            limits={"cpu": "500m", "memory": "512Mi"},
        ),
        is_delete_operator_pod=True,
        get_logs=True,
    )
