# ADR-002: Flagger over Argo Rollouts for Canary Deployments

## Status
Accepted

## Context
Kong API Gateway requires progressive delivery capabilities to safely deploy new versions in production. The canary deployment strategy allows routing a percentage of traffic to the new version while monitoring for errors before full rollout.

Requirements:
- Gradual traffic shifting (10% → 20% → 50% → 100%)
- Automated rollback on metric threshold violations
- Integration with existing monitoring (Prometheus)
- Support for Kong-native traffic splitting
- GitOps compatibility with ArgoCD

Two leading options in the Kubernetes ecosystem:
- **Flagger**: CNCF project with native providers for multiple ingress controllers
- **Argo Rollouts**: Argo project with analysis templates and experiments

## Decision
Use **Flagger** for canary deployments of Kong Gateway.

### Flagger Configuration
```yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: kong-gateway
  namespace: kong
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: kong-gateway
  
  provider: kong  # Native Kong integration
  
  analysis:
    interval: 1m
    threshold: 5
    maxWeight: 50
    stepWeight: 10
    metrics:
      - name: request-success-rate
        thresholdRange:
          min: 99
        interval: 1m
      - name: request-duration
        thresholdRange:
          max: 500
        interval: 1m
```

### Canary Progression
```
0% → 10% → 20% → 40% → 60% → 80% → 100%
     ↓
  Analysis (every 1m)
     ↓
  Fail? → Automatic Rollback
```

## Consequences

### Positive
- **Native Kong provider**: Flagger has first-class support for Kong traffic splitting via Kong Ingress Controller annotations
- **Simpler configuration**: Single Canary CRD vs multiple Rollout + AnalysisTemplate CRDs
- **Built-in metric templates**: Pre-configured Prometheus queries for success rate and latency
- **CNCF project**: Active community, production-proven at scale
- **Webhook support**: Slack/Teams notifications on canary events
- **ArgoCD compatible**: Works seamlessly with GitOps workflows

### Negative
- **Less flexible than Argo Rollouts**: No support for experiments or analysis templates composition
- **Single analysis interval**: Cannot have different check intervals for different metrics
- **Limited blue-green support**: Primarily designed for canary, blue-green is secondary
- **Requires Prometheus**: Metric analysis depends on Prometheus (or Datadog/CloudWatch with adapters)

### Production Impact
- **Deployment time**: ~6 minutes for full rollout (10% steps with 1m analysis)
- **Rollback time**: <30 seconds automatic rollback on threshold violation
- **Resource overhead**: Flagger controller (~100Mi memory)

## Alternatives Considered

### Argo Rollouts
**Rejected**: While more feature-rich, Argo Rollouts requires:
- Separate AnalysisTemplate CRDs for each metric
- Manual configuration of traffic splitting annotations
- No native Kong provider (requires generic traefik or nginx style annotations)
- More complex setup for equivalent functionality

For Kong specifically, Flagger's native provider simplifies the integration significantly.

### Manual Canary with Kong Rate Limiting
**Rejected**: Using Kong's request-transformer or rate-limiting plugins for traffic splitting:
- Requires manual percentage adjustments
- No automated rollback
- No metric analysis
- Operationally complex

### Blue-Green Deployments Only
**Rejected**: Blue-green provides instant cutover but:
- No gradual traffic shifting
- Higher blast radius on failures
- Cannot detect issues with partial traffic before full rollout
- Requires 2x resources during deployment

### No Progressive Delivery (Rolling Updates)
**Rejected for Production**: Rolling updates:
- Expose all users to new version simultaneously
- Rollback requires full redeployment
- Cannot limit blast radius of bugs
- Acceptable for dev/staging only
