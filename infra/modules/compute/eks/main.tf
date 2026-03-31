# EKS Module - Core Cluster Only
# Helm addons (ALB Controller, Karpenter) are deployed separately at the
# environment level to avoid circular dependencies with IRSA roles.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Core EKS Cluster using terraform-aws-modules/eks/aws
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access  = var.cluster_endpoint_public_access
  cluster_endpoint_private_access = var.cluster_endpoint_private_access

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # Additional security groups
  cluster_additional_security_group_ids = var.security_group_ids

  # Use the role ARN passed from IAM module
  create_iam_role = var.create_cluster_iam_role
  iam_role_arn    = var.cluster_role_arn

  # Node Security Group - allow all egress for ECR, SSM, EKS API access
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  # EKS Managed Node Groups
  eks_managed_node_groups = var.node_groups

  # Cluster addons (AWS native only - Helm addons deployed separately)
  cluster_addons = {
    coredns = var.addons.coredns ? {
      most_recent = true
    } : null

    kube-proxy = var.addons.kube_proxy ? {
      most_recent = true
    } : null

    vpc-cni = var.addons.vpc_cni ? {
      most_recent = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    } : null

    eks-pod-identity-agent = var.addons.pod_identity_agent ? {
      most_recent = true
    } : null
  }

  # Access entries for cluster admin
  enable_cluster_creator_admin_permissions = true

  tags = var.tags
}

# NOTE: Addons (ALB Controller, Karpenter) should be deployed as separate
# modules in the environment layer to avoid circular dependencies with IRSA roles.
# They are no longer included as internal submodules of this EKS module.
