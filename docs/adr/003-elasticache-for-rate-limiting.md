# ADR-003: ElastiCache Redis for Distributed Rate Limiting

## Status
Accepted

## Context
Kong API Gateway in HA mode runs multiple pods across availability zones. Rate limiting must be consistent across all pods - if a client is rate-limited by one pod, all pods must enforce the same limit. This requires a distributed counter store.

Without distributed rate limiting:
- Each pod maintains independent counters
- Client can multiply their rate limit by number of pods
- 3 pods × 1000 req/min = 3000 req/min effective limit

Rate limiting options:
- **local**: In-memory per-pod counters (not suitable for HA)
- **redis**: Distributed counters via Redis
- **cluster**: Kong Enterprise only (not applicable)

For Redis deployment:
- **ElastiCache Multi-AZ**: AWS managed Redis with automatic failover
- **Redis Sentinel on Kubernetes**: Self-managed with Sentinel for failover

## Decision
Use **ElastiCache Redis Multi-AZ** for production and **Redis Sentinel on Kubernetes** for dev/staging.

### Production Configuration (ElastiCache)
```yaml
apiVersion: configuration.konghq.com/v1
kind: KongClusterPlugin
metadata:
  name: global-rate-limit
plugin: rate-limiting
config:
  minute: 1000
  hour: 50000
  policy: redis
  redis_host: master.my-redis.abc123.use1.cache.amazonaws.com
  redis_port: 6379
  redis_ssl: true
  redis_ssl_verify: true
  redis_timeout: 1000
  fault_tolerant: true
  hide_client_headers: false
  limit_by: consumer
```

### Dev/Staging Configuration (Sentinel)
```yaml
config:
  policy: redis
  redis_sentinel_master: mymaster
  redis_sentinel_addresses:
    - redis-sentinel-0.redis-sentinel:26379
    - redis-sentinel-1.redis-sentinel:26379
    - redis-sentinel-2.redis-sentinel:26379
```

## Consequences

### Positive
- **Consistent rate limiting**: All Kong pods share counters, enforcing true limits
- **99.99% SLA (ElastiCache)**: AWS guarantees availability for production workloads
- **Automatic failover**: ElastiCache promotes replica within ~30 seconds
- **Zero operational overhead**: No patching, backup management, or monitoring setup
- **Encryption**: In-transit (TLS) and at-rest encryption by default
- **Multi-AZ replication**: Data replicated across 3 AZs for durability
- **Fault tolerant mode**: If Redis is unavailable, Kong allows requests (configurable)

### Negative
- **Additional cost**: ~$50/month for cache.t4g.small Multi-AZ cluster
- **Network dependency**: Kong pods must reach ElastiCache endpoint
- **Single point of coordination**: All rate limiting depends on Redis availability
- **Latency added**: Each rate-limited request adds Redis roundtrip (~1-2ms)
- **VPC lock-in**: ElastiCache is VPC-bound, complicates multi-cluster scenarios

### Dev/Staging Trade-off
Redis Sentinel on Kubernetes is acceptable because:
- Self-managed overhead is tolerable for non-production
- Cost savings (~$50/month → ~$20/month compute)
- Learning opportunity for team to understand Redis HA
- Acceptable if rate limiting is briefly inconsistent during failover

## Alternatives Considered

### Local Rate Limiting (No Redis)
**Rejected**: Fundamentally broken for HA deployments:
- 3 pods = 3x effective rate limit
- Cannot guarantee API abuse prevention
- Defeats purpose of rate limiting

### DynamoDB for Counters
**Rejected**: While DynamoDB provides distributed counters:
- Higher latency than Redis (~5-10ms vs ~1-2ms)
- More complex atomic increment patterns
- Kong's rate-limiting plugin doesn't natively support DynamoDB
- Would require custom plugin development

### Redis Cluster Mode
**Rejected**: Redis Cluster (sharding) is overkill:
- Rate limiting doesn't need horizontal scaling of Redis
- Single master handles millions of increments/second
- Adds complexity without benefit
- ElastiCache Multi-AZ provides sufficient redundancy

### Redis on EC2 (Self-Managed)
**Rejected**: Managing Redis on EC2:
- Operational burden: patching, backups, monitoring
- No automatic failover without custom tooling
- Similar cost to ElastiCache without the managed benefits
- Team time better spent on application features

### Kong Enterprise (Cluster Strategy)
**Rejected**: Kong Enterprise provides native clustering:
- Requires Kong Enterprise license (~$15k+/year)
- For POC/initial deployment, open-source + Redis is sufficient
- Can migrate to Enterprise later if needed
