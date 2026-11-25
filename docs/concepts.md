# KEDA Concepts Reference

Reference for the terms used across all three demos. Each demo README links back to the relevant sections here.

## KEDA Operator

The KEDA Operator is the controller that runs in the cluster (by convention in the `keda` namespace). It watches `ScaledObject` resources and, for each one, creates and manages a native Horizontal Pod Autoscaler (HPA) to drive the target workload's replica count. It also runs the metrics adapter that feeds external metrics (queue length, schedule state, etc.) to the HPA.

Used in: all demos.

## ScaledObject

A KEDA custom resource (`keda.sh/v1alpha1`) that declares how a target `Deployment` should scale. Key fields:

- `scaleTargetRef` — the Deployment to scale.
- `minReplicaCount` / `maxReplicaCount` — the replica bounds.
- `pollingInterval` — how often KEDA checks the trigger (seconds).
- `cooldownPeriod` — how long to wait before scaling down after the last trigger activity.
- `triggers[]` — one or more event sources (scalers) that drive scaling.

Used in: all demos.

## Scaler

The pluggable component inside KEDA that connects to a specific event source and reports a metric. This suite uses three:

- **cron** — scales on a time schedule (Demos 1 and 3).
- **rabbitmq** — scales on RabbitMQ queue length (Demo 2).
- **aws-sqs-queue** — scales on Amazon SQS message count (Demo 4).

## HPA (Horizontal Pod Autoscaler)

The native Kubernetes resource that actually changes replica counts based on metrics. You do **not** create it directly in these demos — applying a ScaledObject causes KEDA to create one named `keda-hpa-<scaledobject-name>`. Deleting the ScaledObject removes the HPA.

Used in: all demos (observed directly in Demo 1).

## Deployment and Pod

A **Deployment** manages a replicated set of **Pods**. KEDA scales the Deployment; Kubernetes creates or removes Pods to match. The worker application in every demo runs as Pods behind a Deployment named `worker`.

## Queue length (event-driven scaling)

The number of unprocessed messages in a queue. KEDA converts it to desired replicas:

```
desiredReplicas = ceil(queueLength / targetValuePerReplica)   # bounded by [min, max]
```

For example, with a target of 10 messages per replica and 300 messages queued, KEDA targets `ceil(300/10) = 30` replicas (capped at `maxReplicaCount`). As consumers drain the queue, the count falls back toward the minimum after the cooldown.

Used in: Demo 2 (RabbitMQ), Demo 4 (SQS).

## Cron scaling (scheduled capacity planning)

The cron scaler sets a target replica count during a time window and falls back outside it:

- Inside `[start, end]` → `desiredReplicas`.
- Outside the window → `minReplicaCount`.

This is proactive scaling (scale up before predicted load) rather than reactive. Used in Demo 1 (as a dependency-free way to show the mechanics) and Demo 3 (scheduled capacity planning).

## Node autoscaling and Pending Pods

When KEDA scales a Deployment beyond the cluster's available compute capacity, the Kubernetes scheduler cannot place the extra Pods, so they enter the **Pending** state. A **Node Autoscaler** (Karpenter or Cluster Autoscaler) watches for Pending Pods and provisions additional nodes; once capacity is available, the scheduler places the Pending Pods onto the new nodes.

This is a two-layer scaling story: KEDA scales Pods, the node autoscaler scales nodes. Demonstrated in Demo 4 on EKS.
