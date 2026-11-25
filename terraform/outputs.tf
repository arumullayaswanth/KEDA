output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "sqs_queue_url" {
  description = "SQS queue URL — use in the Demo 3 worker/ScaledObject and the load generator."
  value       = aws_sqs_queue.tasks.url
}

output "sqs_queue_arn" {
  description = "SQS queue ARN."
  value       = aws_sqs_queue.tasks.arn
}

output "keda_operator_role_arn" {
  description = "IRSA role ARN already annotated on the KEDA operator ServiceAccount."
  value       = aws_iam_role.keda_operator.arn
}

output "connect_command" {
  description = "Run this on your client to connect kubectl to the cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
