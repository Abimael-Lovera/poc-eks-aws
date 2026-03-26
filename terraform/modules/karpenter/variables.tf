variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster endpoint"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA"
  type        = string
}

variable "node_security_group_id" {
  description = "Security group ID for EKS nodes"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for Karpenter nodes"
  type        = list(string)
}

variable "install_helm_chart" {
  description = "Install Karpenter Helm chart"
  type        = bool
  default     = true
}

variable "chart_version" {
  description = "Version of the Karpenter Helm chart"
  type        = string
  default     = "1.0.1"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
