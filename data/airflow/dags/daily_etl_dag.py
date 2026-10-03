from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator

default_args = {
    "owner": "eq-tech",
    "retries": 2,
    "retry_delay": timedelta(minutes=10),
    "email_on_failure": False,
}


def extract(**kwargs):
    """Simulates pulling price data from a source system."""
    data = {
        "symbols": ["AAPL", "MSFT", "GOOG"],
        "prices":  [185.50, 415.20, 175.80],
    }
    kwargs["ti"].xcom_push(key="raw_data", value=data)
    print(f"Extracted {len(data['symbols'])} symbols")


def transform(**kwargs):
    """Computes simple daily returns from extracted prices."""
    raw = kwargs["ti"].xcom_pull(key="raw_data", task_ids="extract")
    baseline = 180.0
    returns = {
        sym: round((price - baseline) / baseline, 4)
        for sym, price in zip(raw["symbols"], raw["prices"])
    }
    kwargs["ti"].xcom_push(key="returns", value=returns)
    print(f"Computed returns: {returns}")


def load(**kwargs):
    """Simulates writing transformed data to a target store."""
    returns = kwargs["ti"].xcom_pull(key="returns", task_ids="transform")
    # In production: write to Azure Blob Storage or PostgreSQL
    print(f"Loaded {len(returns)} return records to data store")
    for sym, ret in returns.items():
        print(f"  {sym}: {ret:+.2%}")


with DAG(
    dag_id="daily_etl",
    description="Daily ETL: extract → transform → load",
    schedule="0 6 * * 1-5",  # weekdays at 06:00 UTC
    start_date=datetime(2024, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["etl", "daily"],
) as dag:

    t_extract   = PythonOperator(task_id="extract",   python_callable=extract)
    t_transform = PythonOperator(task_id="transform", python_callable=transform)
    t_load      = PythonOperator(task_id="load",      python_callable=load)

    t_extract >> t_transform >> t_load
