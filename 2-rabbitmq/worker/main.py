#!/usr/bin/env python3
"""Demo 2 (RabbitMQ) worker — consumer mode.

Consumes one message at a time from a RabbitMQ queue, "processes" it by sleeping
PROCESS_SECONDS, then acks. The deliberate sleep lets a backlog build so scaling
is visible.

Configuration (environment variables):
  AMQP_URL         RabbitMQ connection string (required)
  QUEUE_NAME       queue to consume            (default: tasks)
  PROCESS_SECONDS  simulated work per message  (default: 5)
"""

import logging
import os
import signal
import time

import pika

LOG_FORMAT = "%(asctime)s %(levelname)s %(message)s"
logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)
log = logging.getLogger("worker")

QUEUE_NAME = os.getenv("QUEUE_NAME", "tasks")
PROCESS_SECONDS = float(os.getenv("PROCESS_SECONDS", "5"))

_running = True


def _handle_signal(signum, _frame):
    global _running
    log.info("received signal %s, shutting down", signum)
    _running = False


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)


def main():
    amqp_url = os.environ["AMQP_URL"]
    log.info("starting in rabbitmq mode, queue=%s", QUEUE_NAME)

    while _running:
        try:
            params = pika.URLParameters(amqp_url)
            connection = pika.BlockingConnection(params)
            channel = connection.channel()
            channel.queue_declare(queue=QUEUE_NAME, durable=True)
            # Fetch one message at a time so a backlog builds and scaling is visible.
            channel.basic_qos(prefetch_count=1)

            for method, _props, body in channel.consume(QUEUE_NAME, inactivity_timeout=1):
                if not _running:
                    break
                if method is None:
                    continue  # inactivity timeout, re-check _running
                log.info("processing message (%d bytes), sleeping %ss", len(body or b""), PROCESS_SECONDS)
                time.sleep(PROCESS_SECONDS)
                channel.basic_ack(method.delivery_tag)
                log.info("acked message")

            channel.cancel()
            connection.close()
        except Exception as exc:  # noqa: BLE001 - demo worker retries on any broker error
            log.warning("rabbitmq connection error: %s; retrying in 3s", exc)
            time.sleep(3)

    log.info("worker stopped")


if __name__ == "__main__":
    main()
