# ElastiCache Redis Module - Multi-AZ Redis for Kong rate limiting
# Configured with automatic failover and encryption
# Security Group is received as input (managed externally)

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_region" "current" {}

# ─────────────────────────────────────────────────────────────────
# Subnet Group - Redis nodes spread across AZs
# ─────────────────────────────────────────────────────────────────

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.cluster_name}-redis-subnet"
  subnet_ids = var.subnet_ids

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-redis-subnet"
    }
  )
}

# ─────────────────────────────────────────────────────────────────
# Parameter Group - Optimized for rate limiting
# ─────────────────────────────────────────────────────────────────

resource "aws_elasticache_parameter_group" "this" {
  name   = "${var.cluster_name}-redis-params"
  family = "redis7"

  # Optimizations for rate limiting workload
  parameter {
    name  = "maxmemory-policy"
    value = "volatile-lru"
  }

  # Enable keyspace notifications (useful for monitoring)
  parameter {
    name  = "notify-keyspace-events"
    value = "Ex"
  }

  tags = var.tags
}

# ─────────────────────────────────────────────────────────────────
# Replication Group - Multi-AZ Redis cluster
# ─────────────────────────────────────────────────────────────────

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.cluster_name
  description          = "Redis for Kong rate limiting - ${var.cluster_name}"

  # Engine configuration
  engine               = "redis"
  engine_version       = var.engine_version
  node_type            = var.node_type
  parameter_group_name = aws_elasticache_parameter_group.this.name

  # High availability
  num_cache_clusters         = var.num_cache_clusters
  automatic_failover_enabled = var.num_cache_clusters > 1
  multi_az_enabled           = var.num_cache_clusters > 1

  # Networking
  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = var.security_group_ids
  port               = 6379

  # Encryption
  at_rest_encryption_enabled = var.at_rest_encryption
  transit_encryption_enabled = var.transit_encryption
  auth_token                 = var.transit_encryption ? var.auth_token : null

  # Maintenance
  maintenance_window       = var.maintenance_window
  snapshot_window          = var.snapshot_window
  snapshot_retention_limit = var.snapshot_retention_limit

  # Auto minor version upgrade
  auto_minor_version_upgrade = true

  # Apply changes immediately (set to false for prod safety)
  apply_immediately = var.apply_immediately

  tags = merge(
    var.tags,
    {
      Name = var.cluster_name
    }
  )

  lifecycle {
    ignore_changes = [
      engine_version,
    ]
  }
}

# ─────────────────────────────────────────────────────────────────
# CloudWatch Alarms (optional)
# ─────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "cpu" {
  count = var.create_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${var.cluster_name}-redis-cpu"
  alarm_description   = "Redis CPU utilization high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 75

  dimensions = {
    CacheClusterId = aws_elasticache_replication_group.this.id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "memory" {
  count = var.create_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${var.cluster_name}-redis-memory"
  alarm_description   = "Redis memory utilization high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    CacheClusterId = aws_elasticache_replication_group.this.id
  }

  tags = var.tags
}
