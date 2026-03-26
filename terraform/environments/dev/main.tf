# POC EKS AWS - Dev Environment
# Main configuration that wires all modules together

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }

  # Backend configured via -backend-config flag
  backend "s3" {}
}

# ─────────────────────────────────────────────────────────────────
# Providers
# ─────────────────────────────────────────────────────────────────

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

# ─────────────────────────────────────────────────────────────────
# Local Variables
# ─────────────────────────────────────────────────────────────────

locals {
  cluster_name = "poc-eks-${var.environment}"

  common_tags = {
    Project     = "poc-eks-aws"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ─────────────────────────────────────────────────────────────────
# VPC Module
# ─────────────────────────────────────────────────────────────────

module "vpc" {
  source = "../../modules/vpc"

  vpc_name           = "${local.cluster_name}-vpc"
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  cluster_name       = local.cluster_name

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────
# ALB Controller Module (creates SG before EKS)
# ─────────────────────────────────────────────────────────────────

module "alb_controller" {
  source = "../../modules/alb-controller"

  cluster_name       = local.cluster_name
  vpc_id             = module.vpc.vpc_id
  oidc_provider_arn  = module.eks.oidc_provider_arn
  install_helm_chart = true

  tags = local.common_tags

  depends_on = [module.eks]
}

# ─────────────────────────────────────────────────────────────────
# EKS Module
# ─────────────────────────────────────────────────────────────────

module "eks" {
  source = "../../modules/eks"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets

  system_node_instance_types = var.system_node_instance_types
  system_node_min_size       = var.system_node_min_size
  system_node_max_size       = var.system_node_max_size
  system_node_desired_size   = var.system_node_desired_size

  # ALB security group for NodePort access (placeholder - updated after ALB module)
  alb_security_group_id = null

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────
# Bastion Module
# ─────────────────────────────────────────────────────────────────

module "bastion" {
  source = "../../modules/bastion"

  name          = local.cluster_name
  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.public_subnets[0]
  instance_type = var.bastion_instance_type

  tags = local.common_tags
}

# Add bastion role to EKS access (allows kubectl from bastion)
resource "aws_eks_access_entry" "bastion" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.bastion.iam_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.bastion.iam_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.bastion]
}

# ─────────────────────────────────────────────────────────────────
# Karpenter Module
# ─────────────────────────────────────────────────────────────────

module "karpenter" {
  source = "../../modules/karpenter"

  cluster_name           = local.cluster_name
  cluster_endpoint       = module.eks.cluster_endpoint
  oidc_provider_arn      = module.eks.oidc_provider_arn
  node_security_group_id = module.eks.node_security_group_id
  private_subnet_ids     = module.vpc.private_subnets
  install_helm_chart     = true

  tags = local.common_tags

  depends_on = [module.eks]
}

# ─────────────────────────────────────────────────────────────────
# Security Group Rule: Allow ALB to reach NodePorts
# ─────────────────────────────────────────────────────────────────

resource "aws_security_group_rule" "alb_to_nodeport" {
  type                     = "ingress"
  from_port                = 30000
  to_port                  = 32767
  protocol                 = "tcp"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.alb_controller.security_group_id
  description              = "Allow ALB to reach NodePorts (instance mode)"
}
