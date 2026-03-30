# Variables for Production Environment - Propuesta A (IP Mode)

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

# ─────────────────────────────────────────────────────────────────
# VPC Variables
# ─────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones (3 for production HA)"
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "Use single NAT gateway (false for production - one per AZ)"
  type        = bool
  default     = false
}

# ─────────────────────────────────────────────────────────────────
# EKS Variables
# ─────────────────────────────────────────────────────────────────

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "system_node_instance_types" {
  description = "Instance types for system nodes"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "system_node_min_size" {
  description = "Minimum system nodes"
  type        = number
  default     = 3
}

variable "system_node_max_size" {
  description = "Maximum system nodes"
  type        = number
  default     = 6
}

variable "system_node_desired_size" {
  description = "Desired system nodes"
  type        = number
  default     = 3
}

# ─────────────────────────────────────────────────────────────────
# Bastion Variables
# ─────────────────────────────────────────────────────────────────

variable "bastion_instance_type" {
  description = "Instance type for bastion host"
  type        = string
  default     = "t3.micro"
}

# ─────────────────────────────────────────────────────────────────
# ElastiCache Redis Variables
# ─────────────────────────────────────────────────────────────────

variable "redis_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t4g.small"
}

variable "redis_num_cache_clusters" {
  description = "Number of cache clusters (nodes). 2+ enables Multi-AZ with automatic failover"
  type        = number
  default     = 2
}

variable "redis_engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.1"
}

variable "redis_at_rest_encryption" {
  description = "Enable encryption at rest"
  type        = bool
  default     = true
}

variable "redis_transit_encryption" {
  description = "Enable encryption in transit (TLS). Requires auth_token"
  type        = bool
  default     = true
}
