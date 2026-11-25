# KEDA Autoscaling Demos

A suite of three progressive, hands-on demos that teach Kubernetes Event-Driven Autoscaling (KEDA). Each demo is fully self-contained: its own worker application (`worker/`), Kubernetes manifests, helper/load scripts, an observer, an idempotent teardown script, and a written walkthrough.

## Demos

| # | Demo | What you learn | Environment |
|---|------|----------------|-------------|
| 1 | [Cron basics](1-cron/) | KEDA Operator, ScaledObject, Deployment, auto-created HPA, Pods, Cron scaler, min/max replicas, scheduled capacity planning | Local cluster |
| 2 | [RabbitMQ queue scaling](2-rabbitmq/) | Event-driven scaling, queue length, scale-to-zero, replica changes | Local cluster |
| 3 | [KEDA on Amazon EKS](3-eks/) | EKS, Pending Pods, node autoscaling, cloud infrastructure | AWS/EKS |

Recommended order: **1 → 2 → 3**. Each builds on concepts from the previous one.

## Environment

- **Demos 1–2** run on any local Kubernetes cluster: [kind](https://kind.sigs.k8s.io/), [minikube](https://minikube.sigs.k8s.io/), [k3d](https://k3d.io/), or Docker Desktop.
- **Demo 3** requires an AWS account and provisions real cloud resources (EKS cluster, EC2 nodes, SQS). It incurs cost — run its teardown promptly.

## Per-demo layout

Each demo folder contains everything it needs:

- `worker/` — the demo's container image (Dockerfile + app), built for that demo's trigger.
- numbered manifests (`1-namespace.yaml`, `2-...`, …) applied in order.
- `observe.sh` — watch replicas, Pods, ScaledObject/HPA.
- `teardown.sh` — idempotent cleanup.
- `README.md` — the walkthrough.

Shared reference: [`docs/concepts.md`](docs/concepts.md) — notes for every KEDA concept the demos teach.

## Prerequisites (all demos)

| Tool | Minimum version |
|------|-----------------|
| Kubernetes cluster | 1.27+ |
| kubectl | 1.27+ |
| KEDA | 2.14+ |

Per-demo prerequisites are listed in each demo's README.
