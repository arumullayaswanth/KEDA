# Worker image for Demo 3 (EKS). Polls an Amazon SQS queue.
# Build:  docker build -t keda-demos/worker-sqs:1.0 worker
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    WORKER_MODE=sqs \
    AWS_REGION=us-east-1 \
    PROCESS_SECONDS=20

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .

RUN useradd --create-home --uid 10001 worker
USER worker

ENTRYPOINT ["python", "main.py"]
