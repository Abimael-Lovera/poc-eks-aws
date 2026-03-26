# Variables for Dev Environment

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

# VPC Variables
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones"
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = "Use single NAT gateway (cost savings)"
  type        = bool
  default     = true
}

# EKS Variables
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
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum system nodes"
  type        = number
  default     = 4
}

variable "system_node_desired_size" {
  description = "Desired system nodes"
  type        = number
  default     = 2
}

# Bastion Variables
variable "bastion_instance_type" {
  description = "Instance type for bastion host"
  type        = string
  default     = "t3.micro"
}
