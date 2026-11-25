# Demo 1 — KEDA Basics with the Cron Scaler

Your first KEDA demo, explained from zero on **Amazon EKS**. You'll create an EKS cluster, install KEDA, deploy a simple workload, and apply a **cron ScaledObject** that scales the workload up during a time window (11:00 AM–11:00 PM IST) and back down outside it.

Because this demo scales a workload on a *schedule*, the thing being scaled can be any idle container — we use stock `nginx`, so there's nothing to build.

**Learning goals:** KEDA Operator, ScaledObject, Deployment, HPA, Pods, the Cron scaler, min/max replicas, and scheduled capacity planning. See [concepts.md](../docs/concepts.md).

---

## What you'll end up with

```
Namespace keda-demo-cron
 └── Deployment "worker"  (nginx)      ← scaled by KEDA
      ▲
      │ manages replicas via
 ┌────┴─────────────────┐
 │ HPA keda-hpa-worker-cron │          ← auto-created by KEDA
 └────▲─────────────────┘
      │ created/driven by
 ScaledObject "worker-cron"  (cron trigger, 11:00–23:00 IST)
      ▲
 KEDA Operator (in the "keda" namespace)  ← watches the ScaledObject
```

Outside 11:00–23:00 IST → **1 replica**. Inside the window → **4 replicas**.

---

## Step 0 — Prerequisites (install these once)

| Tool | What it's for | Minimum version |
|------|---------------|-----------------|
| An AWS account | Hosts the EKS cluster | — |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (configured with `aws configure`) | Authenticates to AWS | v2 |
| [eksctl](https://eksctl.io/installation/) | Creates the EKS cluster | current |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Talks to the cluster | 1.27+ |
| [Helm](https://helm.sh/docs/intro/install/) | Installs KEDA | 3.x |

Check they're on your PATH:

```bash
aws --version
eksctl version
kubectl version --client
helm version
```

> **Cost note:** an EKS cluster + EC2 nodes cost money. Run [Step 7 teardown](#step-7--teardown) when you're done.

---

## Step 1 — Create an EKS cluster

Create a small cluster named `keda-demo` in `us-east-1` (takes ~15 minutes):

```bash
eksctl create cluster --name keda-demo --region us-east-1 \
  --nodes 2 --node-type t3.small --managed
```

`eksctl` points `kubectl` at the new cluster automatically. Confirm:

```bash
kubectl get nodes
# should list 2 nodes with STATUS "Ready"
```

If you need to reconnect `kubectl` later:

```bash
aws eks update-kubeconfig --name keda-demo --region us-east-1
```

---

## Step 2 — Install the KEDA Operator

KEDA is the controller that watches ScaledObjects and does the scaling.

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace
```

Wait until the KEDA pods are running:

```bash
kubectl get pods -n keda
# wait until keda-operator and keda-operator-metrics-apiserver are Running (1/1)
```

---

## Step 3 — Look at what you're about to apply

Three small files, applied in order:

| File | Kind | Purpose |
|------|------|---------|
| `1-namespace.yaml` | Namespace | isolates the demo in `keda-demo-cron` |
| `2-deployment.yaml` | Deployment | the `worker` (stock `nginx`), starts at 1 replica |
| `3-scaledobject.yaml` | ScaledObject | the cron rule: 4 replicas during 11:00–23:00 IST, else 1 |

The ScaledObject trigger:

```yaml
triggers:
  - type: cron
    metadata:
      timezone: "Asia/Kolkata"
      start: "0 11 * * *"    # 11:00 AM IST
      end: "0 23 * * *"      # 11:00 PM IST
      desiredReplicas: "4"
```

---

## Step 4 — Deploy the demo

From inside this `1-cron` folder:

```bash
kubectl apply -f 1-namespace.yaml
kubectl apply -f 2-deployment.yaml
kubectl apply -f 3-scaledobject.yaml
```

Check that everything came up:

```bash
# Pods should be Running
kubectl get pods -n keda-demo-cron

# Deployment shows READY (e.g. 1/1 or 4/4 depending on the time window)
kubectl get deploy worker -n keda-demo-cron

# The ScaledObject should show READY=True and the HPA KEDA created
kubectl get scaledobject,hpa -n keda-demo-cron
```

Expected output looks roughly like:

```
NAME                        READY   STATUS    RESTARTS   AGE
pod/worker-xxxxxxxxxx-xxxxx   1/1     Running   0          20s

NAME                     READY   UP-TO-DATE   AVAILABLE
deployment.apps/worker   1/1     1            1

NAME                                         READY   ACTIVE
scaledobject.keda.sh/worker-cron             True    ...
horizontalpodautoscaler.../keda-hpa-worker-cron ...
```

That's it — KEDA now owns the scaling.

---

## Step 5 — Observe what KEDA created

Check the ScaledObject, the HPA KEDA created, and the Pods:

```bash
kubectl get scaledobject,hpa,pods -n keda-demo-cron
```

You should see:
- the **ScaledObject** `worker-cron`,
- an **HPA named `keda-hpa-worker-cron`** that KEDA created automatically (you never wrote an HPA — that's the point),
- the **worker Pods**.

Watch the replica count live in another terminal:

```bash
kubectl get deploy worker -n keda-demo-cron -w
```

**Expected behavior:**
- If the current IST time is **between 11:00 AM and 11:00 PM**, the Deployment scales to **4 replicas** (`desiredReplicas`).
- Otherwise it sits at **1 replica** (`minReplicaCount`).
- At each boundary (11:00 and 23:00 IST) you'll see the replica count step up or down.

`maxReplicaCount` (10) is the ceiling KEDA will never exceed.

---

## Step 6 (optional) — See a transition without waiting for 11:00

If you don't want to wait for a real clock boundary, edit the cron window in `3-scaledobject.yaml` to a couple of minutes from now (in IST), then re-apply:

```bash
kubectl apply -f 3-scaledobject.yaml
kubectl get deploy worker -n keda-demo-cron -w
```

You'll see replicas go **1 → 4** when the window opens and **4 → 1** when it closes. Set the times back to `0 11` / `0 23` afterwards to restore the 11:00–23:00 IST window.

---

## Configuration reference

| Value | Where | Purpose | Default |
|-------|-------|---------|---------|
| image | `2-deployment.yaml` | The container being scaled | `nginx:1.27-alpine` |
| `start` / `end` | `3-scaledobject.yaml` cron | The daily window (IST) | `11:00` / `23:00` |
| `timezone` | `3-scaledobject.yaml` cron | Timezone for `start`/`end` | `Asia/Kolkata` (IST) |
| `desiredReplicas` | `3-scaledobject.yaml` cron | Replicas inside the window | `4` |
| `minReplicaCount` | `3-scaledobject.yaml` | Replicas outside the window | `1` |
| `maxReplicaCount` | `3-scaledobject.yaml` | Replica ceiling | `10` |
| `pollingInterval` | `3-scaledobject.yaml` | How often KEDA checks the trigger (s) | `15` |

---

## Step 7 — Teardown

Remove everything this demo created (reverse order):

```bash
kubectl delete -f 3-scaledobject.yaml --ignore-not-found
kubectl delete -f 2-deployment.yaml --ignore-not-found
kubectl delete -f 1-namespace.yaml --ignore-not-found
```

Deleting the ScaledObject also removes the auto-created `keda-hpa-worker-cron` HPA.

To delete the whole EKS cluster afterwards (stops all AWS charges):

```bash
eksctl delete cluster --name keda-demo --region us-east-1
```

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| No `keda-hpa-worker-cron` HPA appears | KEDA not installed/running — check `kubectl get pods -n keda`. |
| Replicas don't change at 11:00/23:00 | Check your expectation is in **IST**; inspect with `kubectl describe scaledobject worker-cron -n keda-demo-cron`. |
| ScaledObject shows `Ready: False` | `kubectl describe scaledobject worker-cron -n keda-demo-cron` and read the Events section. |
| Pods stuck `Pending` | Nodes are out of CPU/memory — lower `maxReplicaCount` or add/enlarge nodes in the node group. |
