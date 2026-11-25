# Install KEDA via Helm. The operator ServiceAccount is annotated with the IRSA
# role so KEDA can read the SQS queue (identityOwner: operator in the ScaledObject).
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  version          = "2.14.2"

  set {
    name  = "serviceAccount.operator.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.keda_operator.arn
  }

  depends_on = [module.eks]
}
