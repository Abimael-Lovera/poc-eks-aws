output "alb_security_group_id" {
  description = "ID of the ALB security group"
  value       = try(aws_security_group.alb[0].id, null)
}

output "alb_security_group_arn" {
  description = "ARN of the ALB security group"
  value       = try(aws_security_group.alb[0].arn, null)
}

output "bastion_security_group_id" {
  description = "ID of the Bastion security group"
  value       = try(aws_security_group.bastion[0].id, null)
}

output "bastion_security_group_arn" {
  description = "ARN of the Bastion security group"
  value       = try(aws_security_group.bastion[0].arn, null)
}

output "elasticache_security_group_id" {
  description = "ID of the ElastiCache security group"
  value       = try(aws_security_group.elasticache[0].id, null)
}

output "elasticache_security_group_arn" {
  description = "ARN of the ElastiCache security group"
  value       = try(aws_security_group.elasticache[0].arn, null)
}
