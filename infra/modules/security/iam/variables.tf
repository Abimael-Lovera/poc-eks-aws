variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "roles" {
  description = "Map of IAM roles to create"
  type = map(object({
    description             = string
    trust_policy            = string                     # JSON string
    policy_json             = optional(string)           # Custom policy JSON (mutually exclusive with policy_arns)
    policy_arns             = optional(list(string), []) # Managed policy ARNs to attach
    create_instance_profile = optional(bool, false)
  }))
  default = {}
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
