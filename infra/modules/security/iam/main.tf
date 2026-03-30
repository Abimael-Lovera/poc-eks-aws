# Generic IAM Module
# Creates roles based on the `roles` map passed by the caller.
# The caller defines WHAT roles exist - this module just creates them.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# Create IAM roles dynamically based on input map
resource "aws_iam_role" "this" {
  for_each = var.roles

  name               = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}"
  description        = each.value.description
  assume_role_policy = each.value.trust_policy

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}"
    Role = each.key
  })
}

# Create policies from JSON content
resource "aws_iam_policy" "this" {
  for_each = { for k, v in var.roles : k => v if length(v.policy_arns) == 0 && v.policy_json != null }

  name        = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}"
  description = "Policy for ${each.value.description}"
  policy      = each.value.policy_json

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}"
  })
}

# Attach custom policies to roles
resource "aws_iam_role_policy_attachment" "custom" {
  for_each = aws_iam_policy.this

  role       = aws_iam_role.this[each.key].name
  policy_arn = each.value.arn
}

# Attach managed policy ARNs to roles (if specified)
resource "aws_iam_role_policy_attachment" "managed" {
  for_each = {
    for item in flatten([
      for role_key, role in var.roles : [
        for policy_arn in role.policy_arns : {
          key        = "${role_key}-${md5(policy_arn)}"
          role_key   = role_key
          policy_arn = policy_arn
        }
      ]
    ]) : item.key => item
  }

  role       = aws_iam_role.this[each.value.role_key].name
  policy_arn = each.value.policy_arn
}

# Create instance profiles for EC2 roles
resource "aws_iam_instance_profile" "this" {
  for_each = { for k, v in var.roles : k => v if v.create_instance_profile }

  name = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}"
  role = aws_iam_role.this[each.key].name

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}"
  })
}
