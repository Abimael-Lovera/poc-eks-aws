output "roles" {
  description = "Map of created IAM roles with their ARNs and names"
  value = {
    for k, v in aws_iam_role.this : k => {
      arn                   = v.arn
      name                  = v.name
      id                    = v.id
      unique_id             = v.unique_id
      instance_profile_name = try(aws_iam_instance_profile.this[k].name, null)
      instance_profile_arn  = try(aws_iam_instance_profile.this[k].arn, null)
    }
  }
}

output "policies" {
  description = "Map of created IAM policies with their ARNs"
  value = {
    for k, v in aws_iam_policy.this : k => {
      arn  = v.arn
      name = v.name
      id   = v.id
    }
  }
}
