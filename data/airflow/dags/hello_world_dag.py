from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator

default_args = {
    "owner": "eq-tech",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="hello_world",
    description="Validates Airflow is running correctly on AKS",
    schedule="@daily",
    start_date=datetime(2024, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["example"],
) as dag:

    greet = BashOperator(
        task_id="greet",
        bash_command="echo 'Hello from EQ Tech Airflow on AKS! Run ID: {{ run_id }}'",
    )

    def log_context(**kwargs):
        print(f"DAG run ID    : {kwargs['run_id']}")
        print(f"Logical date  : {kwargs['logical_date']}")
        print(f"Executor type : KubernetesExecutor")

    log = PythonOperator(
        task_id="log_context",
        python_callable=log_context,
    )

    greet >> log
