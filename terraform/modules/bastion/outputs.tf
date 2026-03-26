output "instance_id" {
  description = "ID of the bastion EC2 instance"
  value       = aws_instance.bastion.id
}

output "public_ip" {
  description = "Public IP of the bastion host"
  value       = aws_instance.bastion.public_ip
}

output "private_ip" {
  description = "Private IP of the bastion host"
  value       = aws_instance.bastion.private_ip
}

output "security_group_id" {
  description = "Security group ID of the bastion"
  value       = aws_security_group.bastion.id
}

output "iam_role_arn" {
  description = "ARN of the bastion IAM role"
  value       = aws_iam_role.bastion.arn
}

output "iam_role_name" {
  description = "Name of the bastion IAM role"
  value       = aws_iam_role.bastion.name
}

output "ssm_connect_command" {
  description = "AWS CLI command to connect via Session Manager"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id}"
}
