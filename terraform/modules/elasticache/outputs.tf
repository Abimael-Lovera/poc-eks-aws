output "replication_group_id" {
  description = "ID of the ElastiCache replication group"
  value       = aws_elasticache_replication_group.this.id
}

output "primary_endpoint" {
  description = "Primary endpoint address for writes"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint" {
  description = "Reader endpoint address for reads (load balanced)"
  value       = aws_elasticache_replication_group.this.reader_endpoint_address
}

output "port" {
  description = "Redis port"
  value       = 6379
}

output "security_group_id" {
  description = "Security group ID for Redis"
  value       = aws_security_group.redis.id
}

output "connection_url" {
  description = "Redis connection URL for Kong rate limiting (without auth)"
  value       = "redis://${aws_elasticache_replication_group.this.primary_endpoint_address}:6379"
}

output "connection_url_tls" {
  description = "Redis connection URL with TLS"
  value       = var.transit_encryption ? "rediss://${aws_elasticache_replication_group.this.primary_endpoint_address}:6379" : null
}
