# -----------------------------------------------------------------------------
# Required Variables
# -----------------------------------------------------------------------------

variable "name" {
  description = "Name prefix for bastion resources"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID where the bastion host will be deployed"
  type        = string
}

variable "iam_instance_profile_name" {
  description = "Name of the IAM instance profile to attach to the bastion"
  type        = string
}

variable "security_group_ids" {
  description = "List of security group IDs to attach to the bastion"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# Optional Variables
# -----------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type for bastion"
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "AMI ID for the bastion host. If null, uses latest Amazon Linux 2023"
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "Size of root volume in GB"
  type        = number
  default     = 20
}

variable "associate_public_ip" {
  description = "Whether to associate a public IP address"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "key_name" {
  description = "SSH key pair name for bastion access. If null, SSH is disabled (SSM only)"
  type        = string
  default     = null
}
