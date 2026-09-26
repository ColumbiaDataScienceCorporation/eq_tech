# Optional custom base image for Airflow worker pods.
# Extend the official image to pre-install heavy Python packages that
# individual task pods would otherwise download on every run.
FROM apache/airflow:2.9.3-python3.11

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

USER airflow

# Add any firm-specific Python packages below
# COPY requirements-workers.txt /tmp/
# RUN pip install --no-cache-dir -r /tmp/requirements-workers.txt
