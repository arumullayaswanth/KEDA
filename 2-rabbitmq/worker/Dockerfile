# Worker image for Demo 2 (RabbitMQ). Consumes from a RabbitMQ queue.
# Build:  docker build -t keda-demos/worker-rabbitmq:1.0 worker
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    WORKER_MODE=rabbitmq \
    QUEUE_NAME=tasks \
    PROCESS_SECONDS=5

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .

RUN useradd --create-home --uid 10001 worker
USER worker

ENTRYPOINT ["python", "main.py"]
