locals {
  cluster_name = "${var.project_name}-${var.environment}"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

data "aws_region" "current" {}

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

  # Managed node groups
  node_groups = {
    general = {
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
    }
  }

  # Addons enabled/disabled via flags (only AWS native addons)
  addons = {
    coredns            = true
    kube_proxy         = true
    vpc_cni            = true
    pod_identity_agent = true
    ebs_csi            = true
    alb_controller     = false # Deployed as separate module below
    karpenter          = false # Deployed as separate module below
    metrics_server     = true
  }

  ebs_csi_role_arn = module.iam_irsa.roles["ebs_csi"].arn

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
    # EBS CSI Driver IRSA role (always created - essential for persistent storage)
    {
      ebs_csi = {
        description = "EBS CSI Driver IRSA Role"
        trust_policy = templatefile("${path.module}/policies/trust/irsa.json.tpl", {
          oidc_provider_arn = module.eks.oidc_provider_arn
          oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")
          namespace         = "kube-system"
          service_account   = "ebs-csi-controller-sa"
        })
        policy_json = file("${path.module}/policies/ebs-csi.json")
      }
    },
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
    } : {},
    # KEDA IRSA role (conditional)
    var.enable_keda ? {
      keda = {
        description = "KEDA Operator IRSA Role"
        trust_policy = templatefile("${path.module}/policies/trust/irsa.json.tpl", {
          oidc_provider_arn = module.eks.oidc_provider_arn
          oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")
          namespace         = "keda"
          service_account   = "keda-operator"
        })
        policy_json = file("${path.module}/policies/keda.json")
      }
    } : {},
    # External Secrets IRSA role (conditional)
    var.enable_external_secrets ? {
      external_secrets = {
        description = "External Secrets Operator IRSA Role"
        trust_policy = templatefile("${path.module}/policies/trust/irsa.json.tpl", {
          oidc_provider_arn = module.eks.oidc_provider_arn
          oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")
          namespace         = "external-secrets"
          service_account   = "external-secrets"
        })
        policy_json = file("${path.module}/policies/external-secrets.json")
      }
    } : {}
  )

  tags = local.tags

  depends_on = [module.eks]
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. HELM ADDONS (ALB Controller, Karpenter, KEDA, External Secrets)
# ─────────────────────────────────────────────────────────────────────────────
# These are deployed AFTER iam_irsa to avoid circular dependencies.

module "alb_controller" {
  source = "../../modules/compute/eks/addons/alb-controller"

  cluster_name        = local.cluster_name
  cluster_endpoint    = module.eks.cluster_endpoint
  vpc_id              = module.vpc.vpc_id
  region              = data.aws_region.current.name
  iam_role_arn        = module.iam_irsa.roles["alb_controller"].arn
  chart_version       = "1.7.1"
  default_target_type = "instance" # Use 'ip' for production with large subnets

  depends_on = [module.eks, module.iam_irsa]
}

module "karpenter" {
  count  = var.enable_karpenter ? 1 : 0
  source = "../../modules/compute/eks/addons/karpenter"

  cluster_name                  = local.cluster_name
  cluster_endpoint              = module.eks.cluster_endpoint
  cluster_certificate_authority = module.eks.cluster_certificate_authority_data
  controller_iam_role_arn       = module.iam_irsa.roles["karpenter_controller"].arn
  node_iam_role_name            = split("/", module.iam_base.roles["karpenter_node"].arn)[1]
  chart_version                 = "1.0.1"

  tags = local.tags

  depends_on = [module.eks, module.iam_irsa]
}

module "keda" {
  count  = var.enable_keda ? 1 : 0
  source = "../../modules/compute/eks/addons/keda"

  cluster_name      = local.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  iam_role_arn      = module.iam_irsa.roles["keda"].arn
  chart_version     = "2.13.0"

  tags = local.tags

  depends_on = [module.eks, module.iam_irsa]
}

module "external_secrets" {
  count  = var.enable_external_secrets ? 1 : 0
  source = "../../modules/compute/eks/addons/external-secrets"

  cluster_name      = local.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  iam_role_arn      = module.iam_irsa.roles["external_secrets"].arn
  chart_version     = "0.9.11"

  tags = local.tags

  depends_on = [module.eks, module.iam_irsa]
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. UPDATE SECURITY GROUP RULES (after EKS is created)
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
# 8. BASTION (needs IAM + SG + VPC)
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
# 9. ELASTICACHE (optional, needs VPC + SG)
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

  tags = local.tags

  depends_on = [module.vpc, module.security_groups]
}
