# Centralized Security Groups Module
# Creates all security groups for the infrastructure

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ALB Security Group
resource "aws_security_group" "alb" {
  count = var.create_alb_sg ? 1 : 0

  name        = "${var.project_name}-${var.environment}-alb"
  description = "Security group for Application Load Balancer"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-alb"
  })
}

# Bastion Security Group
resource "aws_security_group" "bastion" {
  count = var.create_bastion_sg ? 1 : 0

  name        = "${var.project_name}-${var.environment}-bastion"
  description = "Security group for Bastion host"
  vpc_id      = var.vpc_id

  # No ingress rules - SSM Session Manager doesn't need inbound
  # SSH can be added if needed via var.bastion_allowed_cidrs

  dynamic "ingress" {
    for_each = length(var.bastion_ssh_cidrs) > 0 ? [1] : []
    content {
      description = "SSH access"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.bastion_ssh_cidrs
    }
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-bastion"
  })
}

# ElastiCache Security Group
resource "aws_security_group" "elasticache" {
  count = var.create_elasticache_sg ? 1 : 0

  name        = "${var.project_name}-${var.environment}-elasticache"
  description = "Security group for ElastiCache Redis"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = var.eks_node_security_group_ids
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-elasticache"
  })
}

# Rule to allow ALB to reach EKS nodes (for IP mode - direct pod access)
resource "aws_security_group_rule" "alb_to_eks_ip_mode" {
  count = var.create_alb_sg && var.enable_alb_to_eks_rule ? 1 : 0

  type                     = "ingress"
  from_port                = 8000
  to_port                  = 8443
  protocol                 = "tcp"
  security_group_id        = var.eks_node_security_group_ids[0]
  source_security_group_id = aws_security_group.alb[0].id
  description              = "ALB to EKS pods (IP mode)"
}

# Rule to allow ALB to reach EKS NodePorts (for Instance mode)
resource "aws_security_group_rule" "alb_to_eks_nodeport" {
  count = var.create_alb_sg && var.enable_alb_to_eks_rule ? 1 : 0

  type                     = "ingress"
  from_port                = 30000
  to_port                  = 32767
  protocol                 = "tcp"
  security_group_id        = var.eks_node_security_group_ids[0]
  source_security_group_id = aws_security_group.alb[0].id
  description              = "ALB to EKS NodePorts (Instance mode)"
}
