# EKS cluster + a deliberately small managed node group. The small group makes
# the Demo 3 node-autoscaling story visible: scaling the worker past capacity
# produces Pending Pods, which the Cluster Autoscaler then resolves.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access = true

  # Required for IRSA (IAM Roles for Service Accounts).
  enable_irsa = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Give the Terraform-running identity cluster-admin so the kubernetes/helm
  # providers can create resources right after the cluster comes up.
  enable_cluster_creator_admin_permissions = true

  # Small managed node group to run system add-ons, KEDA, and Karpenter itself.
  # Karpenter provisions additional capacity on top of this group on demand.
  eks_managed_node_groups = {
    system = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      labels = {
        role = "system"
      }
    }
  }

  # Tag resources so Karpenter can discover subnets and security groups.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = merge(var.tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })
}
