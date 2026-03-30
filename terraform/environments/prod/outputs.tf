# Outputs for Production Environment

# ─────────────────────────────────────────────────────────────────
# VPC Outputs
# ─────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnets
}

# ─────────────────────────────────────────────────────────────────
# EKS Outputs
# ─────────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "EKS cluster CA certificate"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

# ─────────────────────────────────────────────────────────────────
# ALB Controller Outputs
# ─────────────────────────────────────────────────────────────────

output "alb_security_group_id" {
  description = "ALB security group ID"
  value       = module.alb_controller.security_group_id
}

# ─────────────────────────────────────────────────────────────────
# Bastion Outputs
# ─────────────────────────────────────────────────────────────────

output "bastion_public_ip" {
  description = "Bastion host public IP"
  value       = module.bastion.public_ip
}

output "bastion_ssh_command" {
  description = "SSH command to connect to bastion"
  value       = module.bastion.ssh_command
}

# ─────────────────────────────────────────────────────────────────
# ElastiCache Redis Outputs
# ─────────────────────────────────────────────────────────────────

output "redis_primary_endpoint" {
  description = "Redis primary endpoint (for writes)"
  value       = module.elasticache.primary_endpoint
}

output "redis_reader_endpoint" {
  description = "Redis reader endpoint (for reads, load balanced)"
  value       = module.elasticache.reader_endpoint
}

output "redis_connection_url" {
  description = "Redis connection URL for Kong rate limiting"
  value       = module.elasticache.connection_url
}

output "redis_auth_secret_arn" {
  description = "ARN of the Secrets Manager secret containing Redis auth token"
  value       = var.redis_transit_encryption ? aws_secretsmanager_secret.redis_auth[0].arn : null
}

# ─────────────────────────────────────────────────────────────────
# Kong Configuration Helper
# ─────────────────────────────────────────────────────────────────

output "kong_rate_limit_redis_config" {
  description = "Kong rate limiting Redis configuration"
  value = {
    host       = module.elasticache.primary_endpoint
    port       = 6379
    ssl        = var.redis_transit_encryption
    ssl_verify = var.redis_transit_encryption
  }
}
