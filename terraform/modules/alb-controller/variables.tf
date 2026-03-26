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

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
