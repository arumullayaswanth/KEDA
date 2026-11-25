#!/usr/bin/env python3
"""Demo 3 (EKS) worker — SQS mode.

Polls an Amazon SQS queue, "processes" each message by sleeping PROCESS_SECONDS,
then deletes it.

Configuration (environment variables):
  SQS_QUEUE_URL    SQS queue URL               (required)
  AWS_REGION       AWS region                  (default: us-east-1)
  PROCESS_SECONDS  simulated work per message  (default: 20)
"""

import logging
import os
import signal
import time

import boto3

LOG_FORMAT = "%(asctime)s %(levelname)s %(message)s"
logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)
log = logging.getLogger("worker")

PROCESS_SECONDS = float(os.getenv("PROCESS_SECONDS", "20"))

_running = True


def _handle_signal(signum, _frame):
    global _running
    log.info("received signal %s, shutting down", signum)
    _running = False


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)


def main():
    queue_url = os.environ["SQS_QUEUE_URL"]
    region = os.environ.get("AWS_REGION", "us-east-1")
    log.info("starting in sqs mode, queue=%s region=%s", queue_url, region)

    client = boto3.client("sqs", region_name=region)
    while _running:
        try:
            resp = client.receive_message(
                QueueUrl=queue_url,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=10,
            )
            messages = resp.get("Messages", [])
            if not messages:
                continue
            for msg in messages:
                log.info("processing sqs message, sleeping %ss", PROCESS_SECONDS)
                time.sleep(PROCESS_SECONDS)
                client.delete_message(QueueUrl=queue_url, ReceiptHandle=msg["ReceiptHandle"])
                log.info("deleted sqs message")
        except Exception as exc:  # noqa: BLE001 - demo worker retries on any error
            log.warning("sqs error: %s; retrying in 3s", exc)
            time.sleep(3)

    log.info("worker stopped")


if __name__ == "__main__":
    main()
