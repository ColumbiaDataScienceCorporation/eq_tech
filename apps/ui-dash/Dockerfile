FROM python:3.11-slim
WORKDIR /app
COPY lib/ lib/
COPY apps/ui-dash/requirements.txt requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY apps/ui-dash/app.py app.py
ENV PYTHONPATH=/app
EXPOSE 8050
CMD ["gunicorn", "app:server", "--bind", "0.0.0.0:8050", "--workers", "2"]
