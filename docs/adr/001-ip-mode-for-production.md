# ADR-001: IP Mode for Production Load Balancing

## Status
Accepted

## Context
Kong API Gateway needs efficient load balancing to handle production traffic in our EKS HA architecture. The load balancer must route traffic directly to Kong pods distributed across multiple availability zones with minimal latency and accurate health checking.

Two primary target type modes are available with AWS Load Balancer Controller:
- **IP Mode**: ALB/NLB routes directly to pod IPs
- **Instance Mode**: ALB/NLB routes to node IPs, then iptables NAT to pods

Production workloads require:
- Sub-3ms latency for API gateway responses
- Pod-level health checks for accurate traffic routing
- Graceful handling of pod termination during deployments
- True readiness awareness before receiving traffic

## Decision
Use **ALB IP mode** for production environments and **Instance mode** for dev/staging.

### Production Configuration (IP Mode)
```yaml
apiVersion: v1
kind: Service
metadata:
  name: kong-proxy
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
```

### Requirements for IP Mode
| Requirement | Notes |
|-------------|-------|
| VPC CNI | Default in EKS, must be enabled |
| Subnets /23 or larger | Each pod consumes 1 VPC IP |
| Pod Readiness Gates | Namespace label required |
| Security Groups | ALB SG must allow direct access to Pod SG |

## Consequences

### Positive
- **Lower latency**: ~1-2ms (direct ALB to pod) vs ~3-5ms with Instance mode
- **Pod-level health checks**: ALB detects unhealthy pods immediately, not relying on node health
- **Accurate traffic routing**: No iptables NAT hop means predictable routing
- **Pod readiness gates**: Pods don't receive traffic until fully ready and registered with ALB
- **Better observability**: Direct correlation between ALB metrics and pod metrics

### Negative
- **Higher VPC IP consumption**: Each pod requires a VPC IP address from the subnet CIDR
- **Requires /23 subnets minimum**: To support pod scaling without IP exhaustion
- **More complex setup**: Requires VPC CNI configuration, pod readiness gates, and proper security group rules
- **VPC CNI dependency**: Cannot use alternative CNI plugins like Calico or Cilium
- **Higher infrastructure cost**: ~$303/month (prod) vs ~$195/month (dev/staging)

### Dev/Staging Trade-off
Instance mode is acceptable for non-production because:
- Latency requirements are relaxed (3-5ms acceptable)
- Cost savings outweigh performance benefits
- Simpler setup reduces operational overhead
- No need for /23 subnets (conserves IP space)

## Alternatives Considered

### Instance Mode for All Environments
**Rejected**: Production requires pod-level health checks and <3ms latency. Instance mode's node-level health checks can route traffic to nodes where Kong pods are unhealthy, causing 5xx errors.

### AWS App Mesh
**Rejected**: Adds complexity with sidecar proxies for a use case that doesn't require service mesh features. Kong already provides the API gateway functionality needed.

### Ingress Controller with ClusterIP
**Rejected**: Adds an extra hop through the ingress controller. IP mode provides the most direct path to Kong pods.
