output "iam_role_arn" {
  description = "ARN of the ALB Controller IAM role"
  value       = module.alb_controller_irsa.iam_role_arn
}

output "security_group_id" {
  description = "Security group ID for ALB"
  value       = aws_security_group.alb.id
}
