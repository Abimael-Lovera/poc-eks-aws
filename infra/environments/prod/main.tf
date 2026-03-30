locals {
  cluster_name = "${var.project_name}-${var.environment}"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. VPC (no dependencies)
# ─────────────────────────────────────────────────────────────────────────────

module "vpc" {
  source = "../../modules/networking/vpc"

  vpc_name                  = local.cluster_name
  vpc_cidr                  = var.vpc_cidr
  az_count                  = var.az_count
  single_nat_gateway        = var.single_nat_gateway
  use_large_private_subnets = var.use_large_private_subnets
  cluster_name              = local.cluster_name

  tags = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. SECURITY GROUPS (depends on VPC, created BEFORE EKS)
# ─────────────────────────────────────────────────────────────────────────────
# Creating security groups first breaks circular dependencies.
# EKS can reference ALB SG ID without needing OIDC provider.

module "security_groups" {
  source = "../../modules/security/security-groups"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.vpc.vpc_id

  # Control which security groups to create
  create_alb_sg         = true
  create_bastion_sg     = var.enable_bastion
  create_elasticache_sg = var.enable_elasticache

  # SSH access to bastion (empty list = SSM only)
  bastion_ssh_cidrs = var.bastion_ssh_cidrs

  # We'll add EKS node SG rules in a second pass after EKS is created
  enable_alb_to_eks_rule = false

  tags = local.tags

  depends_on = [module.vpc]
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. BASE IAM ROLES (no OIDC dependency)
# ─────────────────────────────────────────────────────────────────────────────
# These roles don't need EKS OIDC provider, so they can be created first.

module "iam_base" {
  source = "../../modules/security/iam"

  project_name = var.project_name
  environment  = var.environment

  roles = {
    eks_cluster = {
      description  = "EKS Cluster Role"
      trust_policy = file("${path.module}/policies/trust/eks-cluster.json")
      policy_arns = [
        "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
        "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
      ]
    }

    karpenter_node = {
      description             = "Karpenter Node Role"
      trust_policy            = file("${path.module}/policies/trust/ec2.json")
      policy_json             = file("${path.module}/policies/karpenter-node.json")
      create_instance_profile = true
    }

    bastion = {
      description             = "Bastion Host Role"
      trust_policy            = file("${path.module}/policies/trust/ec2.json")
      policy_json             = file("${path.module}/policies/bastion.json")
      create_instance_profile = true
    }
  }

  tags = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. EKS CLUSTER (needs VPC + base IAM, outputs OIDC)
# ─────────────────────────────────────────────────────────────────────────────

module "eks" {
  source = "../../modules/compute/eks"

  cluster_name     = local.cluster_name
  cluster_version  = var.cluster_version
  cluster_role_arn = module.iam_base.roles["eks_cluster"].arn

  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets
  security_group_ids = []

  # Production managed node groups with multiple instance types
  node_groups = {
    general = {
      min_size       = 3
      max_size       = 10
      desired_size   = 3
      instance_types = ["t3.large", "t3a.large"]
      capacity_type  = "ON_DEMAND"
    }
    spot = {
      min_size       = 0
      max_size       = 5
      desired_size   = 2
      instance_types = ["t3.large", "t3a.large"]
      capacity_type  = "SPOT"
    }
  }

  # Karpenter node role ARN (top-level parameter)
  karpenter_node_role_arn = var.enable_karpenter ? module.iam_base.roles["karpenter_node"].arn : null

  # Addons enabled/disabled via flags
  addons = {
    coredns            = true
    kube_proxy         = true
    vpc_cni            = true
    pod_identity_agent = true
    alb_controller     = true
    karpenter          = var.enable_karpenter
    metrics_server     = true
  }

  # IAM role ARNs passed from IAM modules
  # Terraform resolves the dependency graph automatically:
  # 1. EKS cluster creates first → exports OIDC
  # 2. iam_irsa uses OIDC → creates IRSA roles
  # 3. EKS addons (internal resources) wait for the ARN values
  iam_role_arns = {
    alb_controller       = module.iam_irsa.roles["alb_controller"].arn
    karpenter_controller = var.enable_karpenter ? module.iam_irsa.roles["karpenter_controller"].arn : null
  }

  alb_controller_config = {
    chart_version       = "1.7.1"
    default_target_type = "ip" # IP mode for production with large subnets
  }

  karpenter_config = {
    chart_version = "1.0.1"
  }

  tags = local.tags

  depends_on = [module.iam_base, module.vpc, module.security_groups]
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. IRSA ROLES (needs OIDC from EKS)
# ─────────────────────────────────────────────────────────────────────────────
# These roles use OIDC federation, so they must be created AFTER EKS.

module "iam_irsa" {
  source = "../../modules/security/iam"

  project_name = var.project_name
  environment  = var.environment

  roles = merge(
    # ALB Controller IRSA role (always created)
    {
      alb_controller = {
        description = "ALB Controller IRSA Role"
        trust_policy = templatefile("${path.module}/policies/trust/irsa.json.tpl", {
          oidc_provider_arn = module.eks.oidc_provider_arn
          oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")
          namespace         = "kube-system"
          service_account   = "aws-load-balancer-controller"
        })
        policy_json = file("${path.module}/policies/alb-controller.json")
      }
    },
    # Karpenter Controller IRSA role (conditional)
    var.enable_karpenter ? {
      karpenter_controller = {
        description = "Karpenter Controller IRSA Role"
        trust_policy = templatefile("${path.module}/policies/trust/irsa.json.tpl", {
          oidc_provider_arn = module.eks.oidc_provider_arn
          oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")
          namespace         = "karpenter"
          service_account   = "karpenter"
        })
        policy_json = file("${path.module}/policies/karpenter-controller.json")
      }
    } : {}
  )

  tags = local.tags

  depends_on = [module.eks]
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. UPDATE SECURITY GROUP RULES (after EKS is created)
# ─────────────────────────────────────────────────────────────────────────────
# Now that EKS exists, we can add the ALB to EKS node security group rules.

resource "aws_security_group_rule" "alb_to_eks_nodes" {
  count = module.security_groups.alb_security_group_id != null ? 1 : 0

  type                     = "ingress"
  from_port                = 30000
  to_port                  = 32767
  protocol                 = "tcp"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.security_groups.alb_security_group_id
  description              = "Allow ALB to reach EKS NodePort services"
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. BASTION (needs IAM + SG + VPC)
# ─────────────────────────────────────────────────────────────────────────────

module "bastion" {
  count  = var.enable_bastion ? 1 : 0
  source = "../../modules/compute/bastion"

  name                      = "${local.cluster_name}-bastion"
  subnet_id                 = module.vpc.public_subnets[0]
  iam_instance_profile_name = module.iam_base.roles["bastion"].instance_profile_name
  security_group_ids        = [module.security_groups.bastion_security_group_id]

  tags = local.tags

  depends_on = [module.eks, module.security_groups]
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. ELASTICACHE (optional, needs VPC + SG)
# ─────────────────────────────────────────────────────────────────────────────

module "elasticache" {
  count  = var.enable_elasticache ? 1 : 0
  source = "../../modules/data/elasticache"

  cluster_name       = "${local.cluster_name}-redis"
  subnet_ids         = module.vpc.private_subnets
  security_group_ids = [module.security_groups.elasticache_security_group_id]

  node_type          = var.elasticache_node_type
  num_cache_clusters = var.elasticache_num_nodes
  engine_version     = "7.1"

  at_rest_encryption = true
  transit_encryption = true

  # Production settings
  apply_immediately = false

  tags = local.tags

  depends_on = [module.vpc, module.security_groups]
}
