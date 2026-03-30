# VPC Module - Creates networking infrastructure for EKS
# Uses AWS VPC module for best practices

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Calculate subnet CIDRs based on mode
  # IP Mode (production): Private subnets need /23 (512 IPs) for pod networking
  # Instance Mode (dev): /24 (256 IPs) is sufficient
  #
  # VPC: 10.0.0.0/16 (65,536 IPs)
  # IP Mode Layout:
  #   Public:  10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24   (256 IPs each)
  #   Private: 10.0.10.0/23, 10.0.12.0/23, 10.0.14.0/23 (512 IPs each)
  # Instance Mode Layout:
  #   Public:  10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24   (256 IPs each)
  #   Private: 10.0.10.0/24, 10.0.11.0/24, 10.0.12.0/24 (256 IPs each)

  # Public subnets: /24 (small, just for NAT/ALB)
  public_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 1)]

  # Private subnets: /23 for IP mode, /24 for instance mode
  private_subnet_newbits = var.use_large_private_subnets ? 7 : 8
  private_subnets = var.use_large_private_subnets ? [
    # IP Mode: /23 subnets starting at 10.0.10.0
    for i, az in local.azs : cidrsubnet(var.vpc_cidr, 7, i + 5)
    ] : [
    # Instance Mode: /24 subnets
    for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)
  ]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.vpc_name
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  # NAT Gateway for private subnets
  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  # DNS settings
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags required for EKS
  public_subnet_tags = merge(
    var.tags,
    {
      "kubernetes.io/role/elb"                    = "1"
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    }
  )

  private_subnet_tags = merge(
    var.tags,
    {
      "kubernetes.io/role/internal-elb"           = "1"
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
      "karpenter.sh/discovery"                    = var.cluster_name
    }
  )

  tags = merge(
    var.tags,
    {
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    }
  )
}
