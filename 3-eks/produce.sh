#!/usr/bin/env bash
# Publish N messages to the Demo 3 SQS queue to drive scale-up.
# Usage: SQS_QUEUE_URL=<url> ./produce.sh [count]   (default count: 500)
set -uo pipefail

log() { printf '\033[0;34m[keda-demo]\033[0m %s\n' "$*"; }
err() { printf '\033[0;31m[keda-demo]\033[0m %s\n' "$*" >&2; }

COUNT="${1:-500}"
QUEUE_URL="${SQS_QUEUE_URL:-}"
REGION="${AWS_REGION:-us-east-1}"

command -v aws >/dev/null 2>&1 || { err "aws CLI not found on PATH"; exit 1; }

if [ -z "$QUEUE_URL" ]; then
  err "set SQS_QUEUE_URL to the SQS queue URL (see README.md Step 5a)"
  exit 1
fi
if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  err "count must be a non-negative integer, got: $COUNT"
  exit 1
fi

log "Publishing $COUNT messages to $QUEUE_URL ..."

# Send in batches of 10 (the SQS SendMessageBatch limit) for speed.
i=0
while [ "$i" -lt "$COUNT" ]; do
  entries=""
  for j in $(seq 0 9); do
    idx=$((i + j))
    [ "$idx" -ge "$COUNT" ] && break
    entries="${entries} Id=msg${idx},MessageBody=task-${idx}"
  done
  # shellcheck disable=SC2086 - word splitting is intentional for batch entries
  aws sqs send-message-batch --queue-url "$QUEUE_URL" --region "$REGION" \
    --entries ${entries} >/dev/null
  i=$((i + 10))
done

log "Published $COUNT messages. Watch Pods and nodes:"
log "  kubectl get pods -n keda-demo-04 -o wide"
log "  kubectl get nodes -w"
