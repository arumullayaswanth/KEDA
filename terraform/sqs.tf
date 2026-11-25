# SQS queue used as the KEDA event source for Demo 3.
resource "aws_sqs_queue" "tasks" {
  name                       = "keda-demo-tasks"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 3600

  tags = var.tags
}
