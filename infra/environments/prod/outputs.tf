# VPC Outputs
output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = module.vpc.public_subnets
}

# EKS Outputs
output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS cluster API server"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for the cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC Provider for EKS"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "URL of the OIDC Provider for EKS"
  value       = module.eks.oidc_provider_url
}

# Security Group Outputs
output "alb_security_group_id" {
  description = "ID of the ALB security group"
  value       = module.security_groups.alb_security_group_id
}

output "bastion_security_group_id" {
  description = "ID of the Bastion security group"
  value       = module.security_groups.bastion_security_group_id
}

# IAM Outputs
output "iam_roles" {
  description = "Map of created IAM roles"
  value = {
    base = {
      for k, v in module.iam_base.roles : k => {
        arn  = v.arn
        name = v.name
      }
    }
    irsa = {
      for k, v in module.iam_irsa.roles : k => {
        arn  = v.arn
        name = v.name
      }
    }
  }
}

# Bastion Outputs (conditional)
output "bastion_public_ip" {
  description = "Public IP of the bastion host"
  value       = var.enable_bastion ? module.bastion[0].public_ip : null
}

output "bastion_instance_id" {
  description = "Instance ID of the bastion host"
  value       = var.enable_bastion ? module.bastion[0].instance_id : null
}

# ElastiCache Outputs (conditional)
output "elasticache_endpoint" {
  description = "ElastiCache primary endpoint"
  value       = var.enable_elasticache ? module.elasticache[0].primary_endpoint : null
}

output "elasticache_reader_endpoint" {
  description = "ElastiCache reader endpoint"
  value       = var.enable_elasticache ? module.elasticache[0].reader_endpoint : null
}
