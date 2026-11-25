# Karpenter: provisions EC2 nodes on demand when Pods are unschedulable.
# When KEDA scales the worker past the small system node group's capacity,
# Pods go Pending and Karpenter launches new nodes to fit them.

# IAM/IRSA, node role, instance profile, and the SQS interruption queue.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.8"

  cluster_name = module.eks.cluster_name

  # Use Pod Identity for the Karpenter controller (no manual SA annotation).
  enable_pod_identity             = true
  create_pod_identity_association = true

  # Attach the policy nodes need to pull images / join the cluster.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}

# Install the Karpenter controller via Helm (OCI chart).
resource "helm_release" "karpenter" {
  name                = "karpenter"
  namespace           = "kube-system"
  repository          = "oci://public.ecr.aws/karpenter"
  chart               = "karpenter"
  version             = "1.0.6"
  repository_username = null

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "settings.interruptionQueue"
    value = module.karpenter.queue_name
  }
  set {
    name  = "serviceAccount.name"
    value = module.karpenter.service_account
  }

  depends_on = [module.eks]
}

# Default EC2NodeClass: how Karpenter builds nodes (AMI, role, subnet/SG discovery).
resource "kubernetes_manifest" "ec2nodeclass" {
  manifest = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      amiFamily = "AL2023"
      role      = module.karpenter.node_iam_role_name
      amiSelectorTerms = [{
        alias = "al2023@latest"
      }]
      subnetSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = var.cluster_name }
      }]
      securityGroupSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = var.cluster_name }
      }]
    }
  }

  depends_on = [helm_release.karpenter]
}

# Default NodePool: what Karpenter is allowed to launch and its limits.
resource "kubernetes_manifest" "nodepool" {
  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "default" }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          requirements = [
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = ["t3.small", "t3.medium", "t3.large"]
            }
          ]
        }
      }
      limits = {
        cpu = "20"
      }
      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "30s"
      }
    }
  }

  depends_on = [kubernetes_manifest.ec2nodeclass]
}
