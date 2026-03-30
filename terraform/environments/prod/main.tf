# POC EKS AWS - Production Environment
# Propuesta A: IP Mode with ALB, Multi-AZ, ElastiCache Redis, ArgoCD, Flagger

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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
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
# Random password for Redis AUTH (if transit encryption enabled)
# ─────────────────────────────────────────────────────────────────

resource "random_password" "redis_auth" {
  count   = var.redis_transit_encryption ? 1 : 0
  length  = 32
  special = false # ElastiCache auth token doesn't support special chars
}

# ─────────────────────────────────────────────────────────────────
# VPC Module - Production with /23 private subnets for IP Mode
# ─────────────────────────────────────────────────────────────────

module "vpc" {
  source = "../../modules/vpc"

  vpc_name                  = "${local.cluster_name}-vpc"
  vpc_cidr                  = var.vpc_cidr
  az_count                  = var.az_count
  single_nat_gateway        = var.single_nat_gateway
  use_large_private_subnets = true # /23 subnets for IP mode
  cluster_name              = local.cluster_name

  tags = local.common_tags
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

  # For IP mode, ALB routes directly to pods - no NodePort SG rule needed
  alb_security_group_id = null

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────
# ALB Controller Module - Configured for IP Mode
# ─────────────────────────────────────────────────────────────────

module "alb_controller" {
  source = "../../modules/alb-controller"

  cluster_name              = local.cluster_name
  vpc_id                    = module.vpc.vpc_id
  oidc_provider_arn         = module.eks.oidc_provider_arn
  install_helm_chart        = true
  default_target_type       = "ip" # IP Mode for production
  enable_pod_readiness_gate = true # Required for IP mode

  tags = local.common_tags

  depends_on = [module.eks]
}

# ─────────────────────────────────────────────────────────────────
# Security Group Rule: Allow ALB to reach Pod IPs (IP Mode)
# ─────────────────────────────────────────────────────────────────

resource "aws_security_group_rule" "alb_to_pods" {
  type                     = "ingress"
  from_port                = 8000
  to_port                  = 8443
  protocol                 = "tcp"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.alb_controller.security_group_id
  description              = "Allow ALB to reach Kong pods directly (IP mode)"
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

# Add bastion role to EKS access
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
# ElastiCache Redis - Multi-AZ for rate limiting
# ─────────────────────────────────────────────────────────────────

module "elasticache" {
  source = "../../modules/elasticache"

  cluster_name            = "${local.cluster_name}-redis"
  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = module.vpc.private_subnets
  allowed_security_groups = [module.eks.node_security_group_id]

  node_type          = var.redis_node_type
  num_cache_clusters = var.redis_num_cache_clusters
  engine_version     = var.redis_engine_version

  at_rest_encryption = var.redis_at_rest_encryption
  transit_encryption = var.redis_transit_encryption
  auth_token         = var.redis_transit_encryption ? random_password.redis_auth[0].result : null

  maintenance_window       = "sun:05:00-sun:06:00"
  snapshot_window          = "03:00-04:00"
  snapshot_retention_limit = 7

  apply_immediately        = false # Safe for production
  create_cloudwatch_alarms = true

  tags = local.common_tags

  depends_on = [module.vpc]
}

# ─────────────────────────────────────────────────────────────────
# Store Redis auth token in AWS Secrets Manager
# ─────────────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "redis_auth" {
  count = var.redis_transit_encryption ? 1 : 0

  name        = "${local.cluster_name}/redis-auth-token"
  description = "Redis AUTH token for ${local.cluster_name}"

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  count = var.redis_transit_encryption ? 1 : 0

  secret_id     = aws_secretsmanager_secret.redis_auth[0].id
  secret_string = random_password.redis_auth[0].result
}

# ─────────────────────────────────────────────────────────────────
# Namespace for Kong with Pod Readiness Gate label (IP Mode)
# ─────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "kong" {
  metadata {
    name = "kong"

    labels = {
      "elbv2.k8s.aws/pod-readiness-gate-inject" = "enabled"
      "app.kubernetes.io/managed-by"            = "terraform"
    }
  }

  depends_on = [module.eks]
}
