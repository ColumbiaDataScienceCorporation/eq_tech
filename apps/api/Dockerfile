FROM python:3.11-slim
WORKDIR /app
# Copy shared library first (cached layer if lib is unchanged)
COPY lib/ lib/
COPY apps/api/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY apps/api/ apps/api/
ENV PYTHONPATH=/app
EXPOSE 8000
CMD ["uvicorn", "apps.api.main:app", "--host", "0.0.0.0", "--port", "8000"]
