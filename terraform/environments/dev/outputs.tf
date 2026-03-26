# Outputs for Dev Environment

# VPC Outputs
output "vpc_id" {
  description = "ID of the VPC"
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

# EKS Outputs
output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "EKS cluster version"
  value       = module.eks.cluster_version
}

# Bastion Outputs
output "bastion_instance_id" {
  description = "Bastion instance ID"
  value       = module.bastion.instance_id
}

output "bastion_public_ip" {
  description = "Bastion public IP"
  value       = module.bastion.public_ip
}

output "bastion_ssm_command" {
  description = "Command to connect to bastion via SSM"
  value       = module.bastion.ssm_connect_command
}

# Kubeconfig command
output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

# Karpenter Outputs
output "karpenter_node_role_name" {
  description = "IAM role name for Karpenter nodes"
  value       = module.karpenter.node_role_name
}

output "karpenter_instance_profile" {
  description = "Instance profile for Karpenter nodes"
  value       = module.karpenter.instance_profile_name
}
