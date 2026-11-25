# IRSA role that lets the KEDA operator read the SQS queue length.
# The ScaledObject uses identityOwner: operator, so the keda-operator
# ServiceAccount (keda namespace) assumes this role via the cluster OIDC provider.

data "aws_iam_policy_document" "sqs_read" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
    ]
    resources = [aws_sqs_queue.tasks.arn]
  }
}

resource "aws_iam_policy" "sqs_read" {
  name   = "${var.cluster_name}-sqs-read"
  policy = data.aws_iam_policy_document.sqs_read.json
  tags   = var.tags
}

# Trust policy: only the keda-operator ServiceAccount may assume the role.
data "aws_iam_policy_document" "keda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:keda:keda-operator"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keda_operator" {
  name               = "${var.cluster_name}-keda-operator"
  assume_role_policy = data.aws_iam_policy_document.keda_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "keda_operator_sqs" {
  role       = aws_iam_role.keda_operator.name
  policy_arn = aws_iam_policy.sqs_read.arn
}
