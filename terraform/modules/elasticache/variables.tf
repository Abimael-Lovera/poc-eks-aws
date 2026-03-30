variable "cluster_name" {
  description = "Name for the ElastiCache replication group"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where Redis will be deployed"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the ElastiCache subnet group"
  type        = list(string)
}

variable "allowed_security_groups" {
  description = "List of security group IDs allowed to access Redis"
  type        = list(string)
}

variable "node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t4g.small"
}

variable "num_cache_clusters" {
  description = "Number of cache clusters (nodes) in the replication group. Set to 2+ for Multi-AZ"
  type        = number
  default     = 2
}

variable "engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.1"
}

variable "at_rest_encryption" {
  description = "Enable encryption at rest"
  type        = bool
  default     = true
}

variable "transit_encryption" {
  description = "Enable encryption in transit (TLS)"
  type        = bool
  default     = true
}

variable "auth_token" {
  description = "Auth token for Redis (required if transit_encryption is true)"
  type        = string
  sensitive   = true
  default     = null
}

variable "maintenance_window" {
  description = "Weekly maintenance window"
  type        = string
  default     = "sun:05:00-sun:06:00"
}

variable "snapshot_window" {
  description = "Daily snapshot window"
  type        = string
  default     = "03:00-04:00"
}

variable "snapshot_retention_limit" {
  description = "Number of days to retain snapshots"
  type        = number
  default     = 7
}

variable "apply_immediately" {
  description = "Apply changes immediately (false is safer for production)"
  type        = bool
  default     = false
}

variable "create_cloudwatch_alarms" {
  description = "Create CloudWatch alarms for Redis"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
