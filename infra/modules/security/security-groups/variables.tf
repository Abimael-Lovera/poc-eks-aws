variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where security groups will be created"
  type        = string
}

variable "create_alb_sg" {
  description = "Whether to create ALB security group"
  type        = bool
  default     = true
}

variable "create_bastion_sg" {
  description = "Whether to create Bastion security group"
  type        = bool
  default     = true
}

variable "create_elasticache_sg" {
  description = "Whether to create ElastiCache security group"
  type        = bool
  default     = false
}

variable "bastion_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH to bastion (empty = no SSH, use SSM only)"
  type        = list(string)
  default     = []
}

variable "eks_node_security_group_ids" {
  description = "EKS node security group IDs for creating ingress rules"
  type        = list(string)
  default     = []
}

variable "enable_alb_to_eks_rule" {
  description = "Whether to create ALB to EKS security group rules"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
