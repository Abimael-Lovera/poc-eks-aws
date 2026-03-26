# EKS Module - Creates EKS cluster with managed node groups
# Supports Karpenter and ALB Controller integration

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.20"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # Networking
  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnets

  # Cluster access
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Enable IRSA
  enable_irsa = true

  # Cluster addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  # EKS Managed Node Groups
  eks_managed_node_groups = {
    # System node group - runs core components and Karpenter
    system = {
      name = "${var.cluster_name}-system"

      instance_types = var.system_node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.system_node_min_size
      max_size     = var.system_node_max_size
      desired_size = var.system_node_desired_size

      # Use latest EKS optimized AMI
      ami_type = "AL2023_x86_64_STANDARD"

      labels = {
        "node-type" = "system"
      }

      taints = var.system_node_taints

      tags = merge(
        var.tags,
        {
          "Name" = "${var.cluster_name}-system"
        }
      )
    }
  }

  # Node security group additional rules
  node_security_group_additional_rules = {
    # Allow ingress from ALB for instance mode
    ingress_alb_nodeport = {
      description              = "Allow ALB to reach NodePorts"
      protocol                 = "tcp"
      from_port                = 30000
      to_port                  = 32767
      type                     = "ingress"
      source_security_group_id = var.alb_security_group_id
    }
  }

  # Tags for Karpenter auto-discovery
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  # Access entries for cluster administration
  enable_cluster_creator_admin_permissions = true

  access_entries = var.access_entries

  tags = var.tags
}
