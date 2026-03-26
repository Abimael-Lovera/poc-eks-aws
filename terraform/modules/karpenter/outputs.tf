output "controller_role_arn" {
  description = "ARN of the Karpenter controller IAM role"
  value       = module.karpenter_irsa.iam_role_arn
}

output "node_role_arn" {
  description = "ARN of the Karpenter node IAM role"
  value       = module.karpenter_node_role.iam_role_arn
}

output "node_role_name" {
  description = "Name of the Karpenter node IAM role"
  value       = module.karpenter_node_role.iam_role_name
}

output "instance_profile_name" {
  description = "Name of the Karpenter instance profile"
  value       = aws_iam_instance_profile.karpenter.name
}

output "sqs_queue_name" {
  description = "Name of the SQS queue for interruption handling"
  value       = aws_sqs_queue.karpenter.name
}
