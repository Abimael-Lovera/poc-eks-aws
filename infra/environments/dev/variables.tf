variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "poc-eks"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "us-east-1"
}

# VPC Configuration
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to use"
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway (cost savings for non-prod)"
  type        = bool
  default     = true
}

variable "use_large_private_subnets" {
  description = "Use /23 subnets for private (required for IP mode). Set to false for /24 (instance mode)"
  type        = bool
  default     = false
}

# EKS Configuration
variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "enable_karpenter" {
  description = "Enable Karpenter for autoscaling"
  type        = bool
  default     = false
}

# Bastion Configuration
variable "enable_bastion" {
  description = "Enable bastion host"
  type        = bool
  default     = true
}

variable "bastion_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH to bastion (empty = no SSH, use SSM only)"
  type        = list(string)
  default     = []
}

# ElastiCache Configuration
variable "enable_elasticache" {
  description = "Enable ElastiCache Redis"
  type        = bool
  default     = false
}

variable "elasticache_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t4g.small"
}

variable "elasticache_num_nodes" {
  description = "Number of ElastiCache nodes"
  type        = number
  default     = 1
}
