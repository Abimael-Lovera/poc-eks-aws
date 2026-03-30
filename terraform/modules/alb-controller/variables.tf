variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA"
  type        = string
}

variable "install_helm_chart" {
  description = "Install ALB Controller Helm chart"
  type        = bool
  default     = true
}

variable "chart_version" {
  description = "Version of the ALB Controller Helm chart"
  type        = string
  default     = "1.7.1"
}

variable "default_target_type" {
  description = "Default target type for load balancers: 'ip' for IP mode (prod) or 'instance' for instance mode (dev)"
  type        = string
  default     = "instance"

  validation {
    condition     = contains(["ip", "instance"], var.default_target_type)
    error_message = "default_target_type must be either 'ip' or 'instance'"
  }
}

variable "enable_pod_readiness_gate" {
  description = "Enable pod readiness gate injection for IP mode"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
