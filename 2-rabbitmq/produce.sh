#!/usr/bin/env bash
# Publish N messages into the RabbitMQ 'tasks' queue to drive scale-up.
# Usage: ./produce.sh [count]   (default: 300)
#
# Publishes by exec'ing a short Python (pika) snippet inside the RabbitMQ Pod,
# so no local RabbitMQ client is required.
set -uo pipefail

log() { printf '\033[0;34m[keda-demo]\033[0m %s\n' "$*"; }
err() { printf '\033[0;31m[keda-demo]\033[0m %s\n' "$*" >&2; }

NS="keda-demo-02"
QUEUE="tasks"
COUNT="${1:-300}"

command -v kubectl >/dev/null 2>&1 || { err "kubectl not found on PATH"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { err "no reachable Kubernetes cluster"; exit 1; }
kubectl get namespace "$NS" >/dev/null 2>&1 || { err "namespace '$NS' not found (apply the manifests first)"; exit 1; }

if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  err "count must be a non-negative integer, got: $COUNT"
  exit 1
fi

RABBIT_POD="$(kubectl get pods -n "$NS" -l app=rabbitmq -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -z "$RABBIT_POD" ]; then
  err "no RabbitMQ pod found in namespace '$NS'"
  exit 1
fi

log "Publishing $COUNT messages to queue '$QUEUE' via pod $RABBIT_POD ..."

# RabbitMQ management image ships Python 3; publish with a tiny pika script.
kubectl exec -n "$NS" "$RABBIT_POD" -- python3 -c "
import pika, json, datetime
conn = pika.BlockingConnection(pika.URLParameters('amqp://guest:guest@localhost:5672/'))
ch = conn.channel()
ch.queue_declare(queue='$QUEUE', durable=True)
for i in range($COUNT):
    body = json.dumps({'id': i, 'ts': datetime.datetime.utcnow().isoformat()})
    ch.basic_publish(exchange='', routing_key='$QUEUE', body=body,
                     properties=pika.BasicProperties(delivery_mode=2))
conn.close()
print('published $COUNT messages')
" || { err "publish failed (is pika available in the RabbitMQ image?)"; exit 1; }

log "Done. Watch replicas scale up: kubectl get pods -n $NS -w"
