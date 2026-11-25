# Demo 3 — KEDA on Amazon EKS with Node Autoscaling

Run KEDA on a real EKS cluster, drive worker Pods with Amazon SQS, and watch what happens when scaling exceeds cluster capacity: Pods go `Pending`, the node autoscaler adds compute, and the Pending Pods get scheduled. This is the production-focused demo.

**Learning goals:** EKS, Kubernetes Pods, node autoscaling, Pending Pods, cloud infrastructure. See [concepts.md](../docs/concepts.md).

> **Cost warning:** this demo provisions a real EKS cluster, EC2 nodes, ECR, and an SQS queue. These cost money. Run the [teardown](#step-9--teardown) as soon as you are done.

This README has two paths:
- **Main steps (CLI):** fastest, uses `eksctl`/`aws`/`kubectl`.
- **[Appendix: AWS Console walkthrough](#appendix--aws-console-click-by-click):** the same thing click-by-click in the AWS web UI, if you prefer not to use the CLI.

---

## How it works

```
./produce.sh 500 ──▶ SQS queue ◀── reads length ── KEDA Operator
                                                       │ scales
                                                       ▼
                                        Deployment "worker" (0 → up to 50)
                                                       │ needs capacity
                                                       ▼
                               too many Pods ──▶ some Pods "Pending"
                                                       │ observed by
                                                       ▼
                                 Node Autoscaler adds EC2 nodes ──▶ Pods scheduled
```

Two layers of scaling: **KEDA scales Pods**, the **node autoscaler scales nodes**.

Resource names used throughout (match the manifests):
- Cluster `keda-demo` · node group `workers` (t3.small, 2–6) · SQS queue `keda-demo-tasks` · ECR repo `keda-demos/worker-sqs` · namespace `keda-demo-04`.

---

## Step 0 — Prerequisites

| Tool / access | Notes |
|---------------|-------|
| AWS account access | Permissions to create EKS, EC2, IAM, SQS, ECR |
| aws CLI (configured with `aws configure`) | v2 |
| eksctl | current |
| kubectl | 1.27+ |
| Helm | 3.x |
| Docker | builds the worker image |
| Node autoscaler | Karpenter or Cluster Autoscaler |

```bash
aws --version && eksctl version && kubectl version --client && helm version && docker version
```

---

## Step 1 — Create the EKS cluster

A deliberately small node group so scaling exhausts it quickly and forces Pending Pods. `--with-oidc` is required for IRSA in Step 5.

```bash
eksctl create cluster --name keda-demo --region us-east-1 \
  --nodes 2 --nodes-min 2 --nodes-max 6 --node-type t3.small \
  --managed --with-oidc
```

Confirm:

```bash
kubectl get nodes      # 2 nodes, STATUS Ready
```

---

## Step 2 — Install KEDA

```bash
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace
kubectl get pods -n keda   # wait until operator pods are Running (1/1)
```

---

## Step 3 — Install a node autoscaler

Install **Karpenter** (recommended — fast provisioning) or the **Cluster Autoscaler**, scoped to the `keda-demo` cluster and the node group's max of 6. Follow the current upstream install guide for your choice. Without this, Pods that don't fit stay `Pending` forever.

---

## Step 4 — Build and push the worker image to ECR

The SQS-consumer worker lives in `worker/`. On EKS the image must be in a registry the cluster can pull from — use ECR.

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGION=us-east-1
export REPO=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/keda-demos/worker-sqs

aws ecr create-repository --repository-name keda-demos/worker-sqs --region $REGION
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
docker build -t keda-demos/worker-sqs:1.0 worker
docker tag keda-demos/worker-sqs:1.0 $REPO:1.0
docker push $REPO:1.0
```

Keep `$REPO:1.0` — it's the `image:` value for `4-worker.yaml`.

---

## Step 5 — Create the SQS queue and grant KEDA access (IRSA)

### 5a. Create the queue

```bash
aws sqs create-queue --queue-name keda-demo-tasks --region us-east-1
export SQS_QUEUE_URL=$(aws sqs get-queue-url --queue-name keda-demo-tasks --region us-east-1 --query QueueUrl --output text)
echo "$SQS_QUEUE_URL"      # copy this
```

### 5b. Why IRSA

KEDA needs permission to read the queue's length. IRSA (IAM Roles for Service Accounts) maps a Kubernetes ServiceAccount to an IAM role via the cluster's OIDC provider — no static AWS keys in the cluster. The ScaledObject uses `identityOwner: operator`, so the **KEDA operator's** ServiceAccount (`keda-operator` in the `keda` namespace) needs the role.

### 5c. Create the SQS read policy

```bash
cat > sqs-read-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage"
      ],
      "Resource": "arn:aws:sqs:us-east-1:${ACCOUNT_ID}:keda-demo-tasks"
    }
  ]
}
JSON

aws iam create-policy --policy-name keda-demo-sqs-read \
  --policy-document file://sqs-read-policy.json
```

### 5d. Bind the policy to the KEDA operator ServiceAccount

```bash
eksctl create iamserviceaccount \
  --cluster keda-demo --region us-east-1 \
  --namespace keda --name keda-operator \
  --attach-policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/keda-demo-sqs-read \
  --override-existing-serviceaccounts --approve

# restart KEDA so it picks up the IRSA-annotated ServiceAccount
kubectl rollout restart deployment keda-operator -n keda
```

---

## Step 6 — Deploy the worker and ScaledObject

Edit the placeholders:
- `4-worker.yaml` → set `image:` to your ECR URI (`$REPO:1.0`) and `SQS_QUEUE_URL` to the queue URL.
- `5-scaledobject.yaml` → set `queueURL` to the same queue URL.

Then apply:

```bash
kubectl apply -f 1-namespace.yaml
kubectl apply -f 4-worker.yaml
kubectl apply -f 5-scaledobject.yaml
```

Check:

```bash
kubectl get scaledobject,hpa,pods -n keda-demo-04
```

---

## Step 7 — Produce load and observe

```bash
export SQS_QUEUE_URL="<your SQS queue URL>"   # if not still set from Step 5a
./produce.sh 500
```

Watch, in separate terminals:

```bash
# Pod states, including Pending, and which node each Pod lands on:
kubectl get pods -n keda-demo-04 -o wide

# Node count changing as the autoscaler adds capacity:
kubectl get nodes -w

# SQS backlog (the scaling metric):
aws sqs get-queue-attributes --queue-url "$SQS_QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages --region us-east-1
```

**Expected observation:** the SQS backlog crosses the threshold (5 messages/replica) and KEDA scales the worker up. The small node group fills, so excess Pods enter `Pending`. The node autoscaler notices the Pending Pods and provisions new nodes; once they join, the scheduler places the Pending Pods onto them. When the queue drains, replicas fall back to 0 and the autoscaler removes the now-idle nodes.

---

## Step 8 — Configuration reference

| Value | Where | Purpose | Default |
|-------|-------|---------|---------|
| node sizes | `eksctl create cluster` flags | Node group capacity | `t3.small`, min 2 / max 6 |
| `SQS_QUEUE_URL` | `4-worker.yaml`, `5-scaledobject.yaml`, env | Target queue | — |
| `queueLength` | `5-scaledobject.yaml` | Target messages per replica | `5` |
| `maxReplicaCount` | `5-scaledobject.yaml` | Upper replica bound | `50` |
| `resources.requests` | `4-worker.yaml` | Pod size (forces Pending Pods) | `300m` / `256Mi` |
| `PROCESS_SECONDS` | `4-worker.yaml` env | Simulated work per message | `20` |
| message count | `produce.sh` arg | Messages to publish | `500` |

---

## Step 9 — Teardown

Remove the Kubernetes resources:

```bash
kubectl delete -f 5-scaledobject.yaml --ignore-not-found
kubectl delete -f 4-worker.yaml --ignore-not-found
kubectl delete -f 1-namespace.yaml --ignore-not-found
```

Delete the SQS queue, the ECR repo, the IRSA policy, and the whole cluster to stop all AWS charges:

```bash
aws sqs delete-queue --queue-url "$SQS_QUEUE_URL" --region us-east-1
aws ecr delete-repository --repository-name keda-demos/worker-sqs --region us-east-1 --force
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/keda-demo-sqs-read
eksctl delete cluster --name keda-demo --region us-east-1
```

(`eksctl delete cluster` also removes the IRSA role/ServiceAccount it created.)

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| Pods never scale up | Confirm messages are in the queue and KEDA has SQS access (IRSA). `kubectl describe scaledobject worker-sqs -n keda-demo-04`. |
| `ImagePullBackOff` | Image URI wrong, or node role missing `AmazonEC2ContainerRegistryReadOnly`. |
| Pods stay `Pending` forever | No node autoscaler installed, or node group `max` reached. |
| KEDA can't read SQS | IRSA role/policy/annotation wrong — re-check Step 5 and `kubectl rollout restart deployment keda-operator -n keda`. |

---

# Appendix — AWS Console click-by-click

If you'd rather not use the CLI, create everything through the AWS Console web UI. Keep **region `us-east-1` (N. Virginia)** selected (top-right) the whole time.

## A — Create the SQS queue

1. Console search bar → **SQS** → open Amazon SQS. Confirm region is **us-east-1**.
2. **Create queue** → Type **Standard** → **Name:** `keda-demo-tasks`.
3. Configuration: **Visibility timeout** `60`s, **Message retention** `1` hour; leave the rest default.
4. **Create queue**. On the details page, copy the **URL** and **ARN** — save both.

## B — Push the worker image to ECR

1. Console → **ECR** → **Create repository** → Private → name `keda-demos/worker-sqs` → **Create**.
2. Open the repo → **View push commands** → run them from this `3-eks` folder, building the local `worker/`:
   ```bash
   aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
   docker build -t keda-demos/worker-sqs:1.0 worker
   docker tag keda-demos/worker-sqs:1.0 <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/keda-demos/worker-sqs:1.0
   docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/keda-demos/worker-sqs:1.0
   ```
3. Confirm the `1.0` tag appears; copy the image URI for `4-worker.yaml`.

## C — Create the EKS cluster

**C1. Cluster IAM role:** IAM → Roles → Create role → AWS service → **EKS → EKS - Cluster** (attaches `AmazonEKSClusterPolicy`) → name `eksClusterRole`.

**C2. Node IAM role:** IAM → Roles → Create role → AWS service → **EC2** → attach `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKS_CNI_Policy` → name `eksNodeRole`.

**C3. Cluster:** EKS → **Add cluster → Create** → Custom configuration (Auto Mode off) → **Name** `keda-demo` → **Version** `1.30` → **Cluster IAM role** `eksClusterRole` → default VPC + 2 subnets, endpoint **Public** → keep default add-ons → **Create**. Wait ~10–15 min until **Active**.

**C4. Node group:** cluster → **Compute** → **Add node group** → **Name** `workers` → **Node IAM role** `eksNodeRole` → instance type **t3.small** → disk `20` GiB → **Desired 2 / Min 2 / Max 6** → **Create**. Wait until **Active**.

**C5. Connect kubectl:**
```bash
aws eks update-kubeconfig --name keda-demo --region us-east-1
kubectl get nodes
```

## D — OIDC + IRSA (give KEDA SQS access)

**D1. OIDC provider:** EKS cluster → **Overview** → copy the **OpenID Connect provider URL**. IAM → **Identity providers → Add provider** → OpenID Connect → paste URL → **Get thumbprint** → Audience `sts.amazonaws.com` → **Add**.

**D2. Policy:** IAM → Policies → Create → JSON (replace `<ACCOUNT_ID>`):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["sqs:GetQueueAttributes","sqs:GetQueueUrl","sqs:ReceiveMessage","sqs:DeleteMessage"],
      "Resource": "arn:aws:sqs:us-east-1:<ACCOUNT_ID>:keda-demo-tasks"
    }
  ]
}
```
Name it `keda-demo-sqs-read`.

**D3. Role:** IAM → Roles → Create role → **Web identity** → select the OIDC provider → Audience `sts.amazonaws.com` → attach `keda-demo-sqs-read` → name `keda-operator-sqs`. Then **Trust relationships → Edit** and set the `sub` condition (replace `<OIDC_ID>` / `<ACCOUNT_ID>`):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>:sub": "system:serviceaccount:keda:keda-operator",
          "oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```
Copy the role ARN.

## E — Install KEDA + node autoscaler (terminal)

```bash
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace

# annotate the operator SA with the IRSA role from D3, then restart
kubectl annotate serviceaccount keda-operator -n keda \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT_ID>:role/keda-operator-sqs --overwrite
kubectl rollout restart deployment keda-operator -n keda
```
Install Cluster Autoscaler (or Karpenter) for the `keda-demo` cluster so Pending Pods trigger new nodes.

## F — Deploy and run

Same as **Step 6** and **Step 7** above (edit placeholders in `4-worker.yaml` / `5-scaledobject.yaml`, apply, run `./produce.sh 500`). You can also send a few messages by hand in the console: **SQS → keda-demo-tasks → Send and receive messages → Send message**.

## Console cleanup

1. EKS → `keda-demo` → Compute → delete the `workers` node group.
2. EKS → delete the `keda-demo` cluster.
3. SQS → delete `keda-demo-tasks`.
4. ECR → delete `keda-demos/worker-sqs`.
5. IAM → delete roles `eksClusterRole`, `eksNodeRole`, `keda-operator-sqs`, the `keda-demo-sqs-read` policy, and the OIDC provider.
