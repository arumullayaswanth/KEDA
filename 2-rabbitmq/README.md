# Demo 2 — Queue-Based Autoscaling with RabbitMQ

The best visual KEDA demo, on **Amazon EKS**. You deploy RabbitMQ and a worker that consumes messages, then publish a burst of messages and watch KEDA scale the worker from **0 up to many replicas** as the backlog grows — and back down to **0** once the queue drains.

**Learning goals:** event-driven scaling, queue length, scale-to-zero, ScaledObject, HPA, replica changes. See [concepts.md](../docs/concepts.md).

---

## How it works

```
./produce.sh 300  ──▶  RabbitMQ queue "tasks"  ◀── reads length ── KEDA Operator
                                                                       │ drives
                                                                       ▼
                                                        HPA keda-hpa-worker-rabbitmq
                                                                       │ scales
                                                                       ▼
                                               Deployment "worker"  (0 → up to 20)
                                                       │ consumes + acks
                                                       └────▶ RabbitMQ queue drains
```

KEDA targets **10 messages per replica**. Publish 300 messages → it scales toward `ceil(300/10)=30`, capped at `maxReplicaCount` (20). As workers drain the queue, replicas fall back to **0** after the cooldown.

---

## Step 0 — Prerequisites (install these once)

| Tool | What it's for | Minimum version |
|------|---------------|-----------------|
| An AWS account | Hosts the EKS cluster | — |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (configured with `aws configure`) | Authenticates to AWS | v2 |
| [eksctl](https://eksctl.io/installation/) | Creates the EKS cluster | current |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Talks to the cluster | 1.27+ |
| [Helm](https://helm.sh/docs/intro/install/) | Installs KEDA | 3.x |
| [Docker](https://docs.docker.com/get-docker/) | Builds the worker image | current |

```bash
aws --version && eksctl version && kubectl version --client && helm version && docker version
```

> **Cost note:** an EKS cluster + EC2 nodes + ECR cost money. Run [Step 8 teardown](#step-8--teardown) when you're done.

---

## Step 1 — Create an EKS cluster

```bash
eksctl create cluster --name keda-demo --region us-east-1 \
  --nodes 2 --node-type t3.small --managed
```

`eksctl` points `kubectl` at the cluster automatically. Confirm:

```bash
kubectl get nodes      # 2 nodes, STATUS Ready
```

Reconnect later if needed:

```bash
aws eks update-kubeconfig --name keda-demo --region us-east-1
```

---

## Step 2 — Install the KEDA Operator

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace
kubectl get pods -n keda   # wait until operator pods are Running (1/1)
```

---

## Step 3 — Build and push the worker image to ECR

The worker (a RabbitMQ consumer) lives in `worker/`. On EKS the image must be in a registry the cluster can pull from — use ECR.

```bash
# set your account id / region once
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGION=us-east-1
export REPO=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/keda-demos/worker-rabbitmq

# create the repo (first time only)
aws ecr create-repository --repository-name keda-demos/worker-rabbitmq --region $REGION

# authenticate, build, tag, push
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
docker build -t keda-demos/worker-rabbitmq:1.0 worker
docker tag keda-demos/worker-rabbitmq:1.0 $REPO:1.0
docker push $REPO:1.0
```

Then edit `5-worker.yaml` and set the `image:` to your ECR URI (`$REPO:1.0`).

---

## Step 4 — Look at what you're about to apply

Six files, applied in order. **Order matters:** the Secret and TriggerAuthentication must exist before the ScaledObject references them.

| File | Kind | Purpose |
|------|------|---------|
| `1-namespace.yaml` | Namespace | isolates the demo in `keda-demo-02` |
| `2-rabbitmq.yaml` | Deployment + Service | single-node RabbitMQ (amqp + management) |
| `3-secret.yaml` | Secret | AMQP connection string (`host` key) |
| `4-trigger-auth.yaml` | TriggerAuthentication | binds the Secret to the trigger |
| `5-worker.yaml` | Deployment | the RabbitMQ consumer, starts at 0 replicas |
| `6-scaledobject.yaml` | ScaledObject | rabbitmq trigger, 10 msgs/replica, 0→20 |

---

## Step 5 — Deploy the demo

```bash
kubectl apply -f 1-namespace.yaml
kubectl apply -f 2-rabbitmq.yaml       # wait until the RabbitMQ pod is Ready
kubectl apply -f 3-secret.yaml
kubectl apply -f 4-trigger-auth.yaml
kubectl apply -f 5-worker.yaml         # starts at 0 replicas
kubectl apply -f 6-scaledobject.yaml
```

Check everything came up:

```bash
# RabbitMQ should be Running; worker starts at 0 replicas
kubectl get pods -n keda-demo-02

# ScaledObject READY=True and the HPA KEDA created
kubectl get scaledobject,hpa -n keda-demo-02
```

---

## Step 6 — Produce load and watch it scale

Publish messages into the queue (defaults to 300):

```bash
./produce.sh 300
```

Watch the Pods scale up in another terminal:

```bash
kubectl get pods -n keda-demo-02 -w
```

Check the current replica count or ScaledObject state any time:

```bash
kubectl get deploy worker -n keda-demo-02
kubectl get scaledobject,hpa,pods -n keda-demo-02
```

See the queue length directly (the scaling metric):

```bash
RABBIT_POD=$(kubectl get pods -n keda-demo-02 -l app=rabbitmq -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n keda-demo-02 "$RABBIT_POD" -- rabbitmqctl list_queues name messages
```

**Expected behavior:** right after `produce.sh`, the queue jumps to ~300 messages and KEDA scales the worker from **0** toward **20** (`ceil(queueLength/10)`, capped at `maxReplicaCount`). As the workers consume (one message per `PROCESS_SECONDS=5s`), the queue drains, and after the `cooldownPeriod` (30s) KEDA scales back down to **0**.

---

## Configuration reference

| Value | Where | Purpose | Default |
|-------|-------|---------|---------|
| message count | `produce.sh` arg | How many messages to publish | `300` |
| `value` | `6-scaledobject.yaml` | Target messages per replica | `10` |
| `minReplicaCount` | `6-scaledobject.yaml` | Lower bound (0 = scale-to-zero) | `0` |
| `maxReplicaCount` | `6-scaledobject.yaml` | Upper bound | `20` |
| `pollingInterval` | `6-scaledobject.yaml` | Queue check frequency (s) | `5` |
| `cooldownPeriod` | `6-scaledobject.yaml` | Wait before scale-down (s) | `30` |
| `PROCESS_SECONDS` | `5-worker.yaml` env | Simulated work per message (s) | `5` |
| image | `5-worker.yaml` | The consumer image (your ECR URI) | `keda-demos/worker-rabbitmq:1.0` |

---

## Step 8 — Teardown

Remove everything this demo created (reverse order):

```bash
kubectl delete -f 6-scaledobject.yaml --ignore-not-found
kubectl delete -f 5-worker.yaml --ignore-not-found
kubectl delete -f 4-trigger-auth.yaml --ignore-not-found
kubectl delete -f 3-secret.yaml --ignore-not-found
kubectl delete -f 2-rabbitmq.yaml --ignore-not-found
kubectl delete -f 1-namespace.yaml --ignore-not-found
```

Deleting the ScaledObject also removes the auto-created `keda-hpa-worker-rabbitmq` HPA.

Delete the ECR repo and the whole cluster to stop all AWS charges:

```bash
aws ecr delete-repository --repository-name keda-demos/worker-rabbitmq --region us-east-1 --force
eksctl delete cluster --name keda-demo --region us-east-1
```

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| Worker Pods never start | Check the image URI in `5-worker.yaml` points at your ECR repo and the push succeeded. |
| ScaledObject `Ready: False` | Apply order wrong — Secret and TriggerAuthentication must exist before the ScaledObject. `kubectl describe scaledobject worker-rabbitmq -n keda-demo-02`. |
| Replicas don't scale up | Confirm messages are in the queue (`rabbitmqctl list_queues`) and the RabbitMQ pod is Ready. |
| `ImagePullBackOff` | Nodes can't pull from ECR — ensure the node role has `AmazonEC2ContainerRegistryReadOnly`. |
