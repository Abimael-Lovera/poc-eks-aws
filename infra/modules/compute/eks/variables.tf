variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "vpc_id" {
  description = "VPC ID where the cluster will be created"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the EKS cluster"
  type        = list(string)
}

variable "cluster_role_arn" {
  description = "ARN of the IAM role for the EKS cluster (from IAM module)"
  type        = string
  default     = null
}

variable "cluster_endpoint_public_access" {
  description = "Enable public access to the cluster endpoint"
  type        = bool
  default     = true
}

variable "cluster_endpoint_private_access" {
  description = "Enable private access to the cluster endpoint"
  type        = bool
  default     = true
}

variable "security_group_ids" {
  description = "Additional security group IDs to attach to the cluster"
  type        = list(string)
  default     = []
}

variable "node_groups" {
  description = "Map of EKS managed node group configurations"
  type        = any
  default     = {}
}

# Addon flags - AWS native addons only
variable "addons" {
  description = "Map of AWS native addon flags to enable/disable"
  type = object({
    coredns            = optional(bool, true)
    kube_proxy         = optional(bool, true)
    vpc_cni            = optional(bool, true)
    pod_identity_agent = optional(bool, true)
    ebs_csi            = optional(bool, true)
    metrics_server     = optional(bool, false)
  })
  default = {}
}

variable "ebs_csi_role_arn" {
  description = "IAM role ARN for EBS CSI driver (required if ebs_csi addon is enabled)"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
