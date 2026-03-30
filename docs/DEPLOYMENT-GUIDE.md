# Deployment Guide

This guide covers the complete deployment process for the POC EKS AWS platform with Kong API Gateway.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Infrastructure Deployment](#infrastructure-deployment)
3. [ArgoCD Setup](#argocd-setup)
4. [Kong Deployment](#kong-deployment)
5. [Canary Deployments with Flagger](#canary-deployments-with-flagger)
6. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Required Tools

| Tool | Minimum Version | Installation |
|------|-----------------|--------------|
| Terraform | >= 1.0 | [terraform.io](https://terraform.io) |
| AWS CLI | v2 | `brew install awscli` |
| kubectl | >= 1.28 | `brew install kubectl` |
| Helm | >= 3.12 | `brew install helm` |
| jq | any | `brew install jq` |

Verify installations:

```bash
terraform version   # >= 1.0
aws --version       # v2.x
kubectl version --client
helm version
```

### AWS Account Setup

#### IAM Permissions

The deploying user/role needs these permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "eks:*",
        "ec2:*",
        "elasticache:*",
        "iam:*",
        "s3:*",
        "dynamodb:*",
        "secretsmanager:*",
        "elasticloadbalancing:*",
        "autoscaling:*",
        "cloudwatch:*",
        "logs:*",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

> **Note**: For production, scope these permissions to specific resources.

#### Configure AWS CLI

```bash
# Option 1: Configure default profile
aws configure

# Option 2: Use named profile
aws configure --profile poc-eks
export AWS_PROFILE=poc-eks
```

### Terraform State Backend

Before deploying infrastructure, initialize the S3 backend for Terraform state:

```bash
# Initialize state backend (creates S3 bucket + DynamoDB table)
make aws-init
```

This creates:
- **S3 Bucket**: `poc-eks-aws-tfstate-<account-id>` (versioned, encrypted)
- **DynamoDB Table**: `poc-eks-aws-tflock` (for state locking)
- **Config File**: `infra/state/backend.conf`

---

## Infrastructure Deployment

### Development Environment

The dev environment uses:
- 2 AZs (cost optimization)
- Single NAT Gateway
- Instance mode (NodePort) for ALB
- Smaller instance types

#### Step 1: Review Configuration

```bash
# Check default variables
cat infra/environments/dev/variables.tf

# Optionally create tfvars override
cp infra/environments/dev/terraform.tfvars.example infra/environments/dev/terraform.tfvars
```

#### Step 2: Plan Infrastructure

```bash
make aws-plan
```

Expected output includes:
- VPC with public/private subnets
- EKS cluster (poc-eks-dev)
- ALB Controller
- Bastion host
- Karpenter for autoscaling

#### Step 3: Apply Infrastructure

```bash
make aws-apply
```

Provisioning takes ~15-20 minutes. Expected resources:

| Resource | Description |
|----------|-------------|
| VPC | 10.0.0.0/16 with 2 AZs |
| EKS Cluster | poc-eks-dev, K8s 1.33 |
| Node Group | 2-4 t3.medium nodes |
| ALB Controller | Instance mode |
| Bastion | t3.micro with SSM |
| Karpenter | Auto-provisioner |

#### Step 4: Configure kubectl

```bash
# Get the command from Terraform output
terraform -chdir=infra/environments/dev output configure_kubectl

# Run it
aws eks update-kubeconfig --region us-east-1 --name poc-eks-dev
```

#### Step 5: Verify Cluster

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

### Production Environment

The prod environment adds:
- 3 AZs (high availability)
- NAT Gateway per AZ
- IP mode for ALB (direct pod routing)
- ElastiCache Redis for rate limiting
- Larger private subnets (/23 for IP mode)

#### Step 1: Plan Production

```bash
make prod-plan
```

Additional resources in prod:
- ElastiCache Redis (Multi-AZ, encrypted)
- Larger subnet CIDRs for IP mode
- Pod Readiness Gates enabled

#### Step 2: Apply Production

```bash
make prod-apply
```

Provisioning takes ~25-30 minutes.

#### Step 3: Configure kubectl for Prod

```bash
terraform -chdir=infra/environments/prod output configure_kubectl
aws eks update-kubeconfig --region us-east-1 --name poc-eks-prod
```

#### Step 4: Get Redis Endpoint

```bash
# For Kong rate limiting configuration
terraform -chdir=infra/environments/prod output redis_primary_endpoint
terraform -chdir=infra/environments/prod output redis_connection_url
```

### What Gets Created

#### Dev Environment

```
VPC (10.0.0.0/16)
├── Public Subnets (2 AZs)
│   ├── NAT Gateway (single)
│   └── Bastion Host
├── Private Subnets (2 AZs)
│   └── EKS Node Group
└── EKS Cluster
    ├── ALB Controller (Instance mode)
    └── Karpenter
```

#### Prod Environment

```
VPC (10.0.0.0/16)
├── Public Subnets (3 AZs)
│   ├── NAT Gateways (one per AZ)
│   └── Bastion Host
├── Private Subnets (3 AZs, /23 for IP mode)
│   ├── EKS Node Group (3 nodes)
│   └── ElastiCache Redis (Multi-AZ)
└── EKS Cluster
    ├── ALB Controller (IP mode)
    ├── Karpenter
    └── Kong namespace (Pod Readiness Gate enabled)
```

---

## ArgoCD Setup

### Install ArgoCD

ArgoCD is installed via a self-managing Application that bootstraps itself:

```bash
# Create the argocd namespace and bootstrap application
kubectl apply -f argocd/bootstrap/argocd-install.yaml
```

This installs:
- ArgoCD v7.7.5 (Helm chart)
- HA configuration (2 replicas per component)
- ALB Ingress for UI access
- RBAC with admin role

### Wait for ArgoCD to be Ready

```bash
# Wait for all pods to be running
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

# Check deployment status
kubectl get pods -n argocd
```

Expected pods:
```
NAME                                               READY   STATUS
argocd-application-controller-0                    1/1     Running
argocd-applicationset-controller-xxx               1/1     Running
argocd-redis-xxx                                   1/1     Running
argocd-repo-server-xxx                             1/1     Running
argocd-server-xxx                                  1/1     Running
```

### Access ArgoCD UI

#### Option 1: Port Forward (Development)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
```

#### Option 2: ALB Ingress (Production)

```bash
# Get the ALB URL
kubectl get ingress -n argocd

# The URL will be something like:
# k8s-argocd-argocd-xxxxx.us-east-1.elb.amazonaws.com
```

### Get Admin Password

```bash
# Initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Login:
- **Username**: admin
- **Password**: (from command above)

### Configure Kong ApplicationSet

Apply the Kong project and ApplicationSet:

```bash
# Create the ArgoCD project (RBAC boundaries)
kubectl apply -f argocd/projects/kong-project.yaml

# Deploy the Kong ApplicationSet (multi-environment)
kubectl apply -f argocd/applicationsets/kong-gateway.yaml

# Deploy Flagger for canary deployments
kubectl apply -f argocd/applicationsets/flagger.yaml
```

Verify applications were created:

```bash
kubectl get applications -n argocd
```

Expected output:
```
NAME          SYNC STATUS   HEALTH STATUS
argocd        Synced        Healthy
kong-dev      Synced        Healthy
kong-staging  OutOfSync     Missing
kong-prod     OutOfSync     Missing
flagger       Synced        Healthy
```

---

## Kong Deployment

### How ArgoCD Deploys Kong

The `kong-gateway` ApplicationSet creates three Applications:

| Application | Namespace | Auto-Sync | Target Type | Replicas |
|-------------|-----------|-----------|-------------|----------|
| kong-dev | kong-dev | Yes | Instance | 2 |
| kong-staging | kong-staging | No | Instance | 2 |
| kong-prod | kong-prod | No | IP | 3 |

Each application uses:
- **Base values**: `helm/values/kong/base.yaml`
- **Environment override**: `helm/values/kong/{dev,staging,prod}.yaml`

### Environment-Specific Configurations

#### Dev Environment (`dev.yaml`)

```yaml
replicaCount: 2
proxy:
  type: NodePort              # Instance mode
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "instance"
resources:
  requests:
    cpu: 100m
    memory: 256Mi
autoscaling:
  enabled: false              # Fixed replicas
env:
  log_level: debug            # Verbose logging
```

#### Prod Environment (`prod.yaml`)

```yaml
replicaCount: 3
proxy:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"  # IP mode
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 10
topologySpreadConstraints:    # Multi-AZ spread
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
```

### IP Mode vs Instance Mode

| Aspect | Instance Mode (Dev) | IP Mode (Prod) |
|--------|---------------------|----------------|
| Traffic Path | ALB -> NodePort -> Pod | ALB -> Pod IP directly |
| Latency | Higher (extra hop) | Lower (direct) |
| IP Usage | Low | Higher (pod IPs) |
| Scaling | Limited by NodePorts | Better pod-level scaling |
| Health Checks | Node-level | Pod-level (more precise) |
| Cost | Lower | Same |

**Why IP mode for production?**
- Direct routing eliminates the NodePort hop
- Pod-level health checks detect failures faster
- Better integration with HPA and Flagger canaries
- Required for precise traffic splitting

### Sync Kong Manually (Staging/Prod)

Dev auto-syncs. For staging and prod, trigger manually:

```bash
# Via CLI
argocd app sync kong-staging
argocd app sync kong-prod

# Or via UI: Applications -> kong-prod -> Sync
```

### Verify Kong Deployment

```bash
# Check pods
kubectl get pods -n kong-dev
kubectl get pods -n kong-prod

# Check services
kubectl get svc -n kong-dev
kubectl get svc -n kong-prod

# Get Kong proxy URL (dev - NodePort via ALB)
kubectl get svc kong-kong-proxy -n kong-dev

# Get Kong proxy URL (prod - LoadBalancer)
kubectl get svc kong-kong-proxy -n kong-prod
```

### Test Kong Health

```bash
# Port-forward for local testing
kubectl port-forward svc/kong-kong-proxy -n kong-dev 8000:80

# Test health endpoint
curl http://localhost:8000/status
```

---

## Canary Deployments with Flagger

Flagger enables progressive delivery with automatic rollback based on metrics.

### How Flagger Works with Kong

1. Flagger watches Deployments with canary annotations
2. Creates a primary (stable) and canary (new) service
3. Gradually shifts traffic using Kong's traffic splitting
4. Monitors success rate and latency via Prometheus
5. Promotes or rolls back based on thresholds

### Create a Canary Resource

Example Canary for a backend service:

```yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: my-app
  namespace: kong-prod
spec:
  # Target deployment
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app

  # Kong ingress reference
  ingressRef:
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    name: my-app

  # Canary analysis
  analysis:
    # Schedule interval
    interval: 30s
    # Max traffic percentage to canary
    maxWeight: 50
    # Traffic increment step
    stepWeight: 10
    # Number of successful checks before promotion
    threshold: 5
    # Metrics for analysis
    metrics:
      - name: request-success-rate
        thresholdRange:
          min: 99
        interval: 1m
      - name: request-duration
        thresholdRange:
          max: 500  # ms
        interval: 1m
```

Apply the canary:

```bash
kubectl apply -f path/to/canary.yaml
```

### Trigger a Canary Deployment

Canary deployments are triggered by updating the deployment's pod spec (image, env, etc.):

```bash
# Update the image
kubectl set image deployment/my-app \
  my-app=my-app:v2 \
  -n kong-prod
```

Flagger detects the change and starts the canary rollout.

### Monitor Canary Progress

```bash
# Watch canary status
kubectl get canary -n kong-prod -w

# Detailed status
kubectl describe canary my-app -n kong-prod

# Check events
kubectl get events -n kong-prod --field-selector reason=Synced
```

Expected progression:
```
NAME     STATUS        WEIGHT   LASTTRANSITIONTIME
my-app   Progressing   0        2024-01-15T10:00:00Z
my-app   Progressing   10       2024-01-15T10:00:30Z
my-app   Progressing   20       2024-01-15T10:01:00Z
...
my-app   Succeeded     0        2024-01-15T10:05:00Z
```

### Manual Rollback

If you need to abort a canary before automatic rollback:

```bash
# Set the canary to failed (triggers rollback)
kubectl patch canary my-app -n kong-prod \
  --type='json' \
  -p='[{"op": "replace", "path": "/status/phase", "value": "Failed"}]'
```

Or via Flagger CLI:

```bash
# If using flagger CLI
flagger -n kong-prod abort my-app
```

### Automatic Rollback Conditions

Flagger automatically rolls back when:

1. **Success rate drops below threshold** (default: 99%)
2. **Latency exceeds threshold** (default: 500ms)
3. **Analysis fails** (threshold iterations with failures)
4. **Health check fails** on canary pods

Check rollback reason:

```bash
kubectl describe canary my-app -n kong-prod | grep -A5 "Status:"
```

---

## Troubleshooting

### Common Issues

#### 1. Terraform State Lock

**Symptom**: `Error acquiring the state lock`

**Solution**:
```bash
# Force unlock (use with caution)
terraform force-unlock <LOCK_ID>
```

#### 2. EKS Authentication Failed

**Symptom**: `error: You must be logged in to the server`

**Solution**:
```bash
# Update kubeconfig
aws eks update-kubeconfig --region us-east-1 --name poc-eks-dev

# Verify identity
aws sts get-caller-identity
```

#### 3. ALB Not Creating

**Symptom**: Ingress stuck in pending, no ALB created

**Solution**:
```bash
# Check ALB Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Common issues:
# - Missing subnet tags
# - IAM role permissions
# - VPC CNI not ready
```

#### 4. Kong Pods Not Ready

**Symptom**: Pods stuck in `0/1 Running`

**Solution**:
```bash
# Check pod events
kubectl describe pod -n kong-dev -l app.kubernetes.io/name=kong

# Check readiness probe
kubectl logs -n kong-dev -l app.kubernetes.io/name=kong

# Common issues:
# - DB connection (should be "off" for DB-less)
# - Resource limits too low
```

#### 5. ArgoCD Sync Failed

**Symptom**: Application shows "OutOfSync" or "Degraded"

**Solution**:
```bash
# Check sync status
argocd app get kong-dev

# View detailed diff
argocd app diff kong-dev

# Force sync with prune
argocd app sync kong-dev --prune
```

#### 6. Flagger Canary Stuck

**Symptom**: Canary shows "Progressing" indefinitely

**Solution**:
```bash
# Check Flagger logs
kubectl logs -n flagger-system -l app.kubernetes.io/name=flagger

# Check Prometheus connectivity
kubectl exec -n flagger-system deploy/flagger -- \
  wget -qO- http://prometheus-server.monitoring:80/api/v1/query?query=up
```

### Useful kubectl Commands

```bash
# Cluster overview
kubectl get nodes -o wide
kubectl top nodes
kubectl top pods -A

# Pod debugging
kubectl logs -f <pod> -n <namespace>
kubectl exec -it <pod> -n <namespace> -- /bin/sh
kubectl describe pod <pod> -n <namespace>

# Network debugging
kubectl run debug --image=nicolaka/netshoot -it --rm -- bash

# Events (sorted by time)
kubectl get events -A --sort-by='.lastTimestamp'

# Resource usage
kubectl get pods -A -o=custom-columns=\
'NAMESPACE:.metadata.namespace,NAME:.metadata.name,CPU:.spec.containers[*].resources.requests.cpu,MEM:.spec.containers[*].resources.requests.memory'
```

### Check ALB Controller Logs

```bash
# Get controller pod
ALB_POD=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o jsonpath='{.items[0].metadata.name}')

# Stream logs
kubectl logs -f $ALB_POD -n kube-system

# Check for specific errors
kubectl logs $ALB_POD -n kube-system | grep -i error
```

### Check Karpenter Logs

```bash
# Get Karpenter pod
KARP_POD=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[0].metadata.name}')

# Stream logs
kubectl logs -f $KARP_POD -n karpenter

# Check provisioner status
kubectl get nodepools
kubectl get ec2nodeclasses
```

### Verify AWS Resources

```bash
# Check ALBs
aws elbv2 describe-load-balancers --query 'LoadBalancers[*].[LoadBalancerName,State.Code,DNSName]' --output table

# Check Target Groups
aws elbv2 describe-target-groups --query 'TargetGroups[*].[TargetGroupName,TargetType,Protocol]' --output table

# Check ElastiCache (prod)
aws elasticache describe-replication-groups --query 'ReplicationGroups[*].[ReplicationGroupId,Status,NodeGroups[*].PrimaryEndpoint.Address]' --output table
```

---

## Quick Reference

### Makefile Commands

| Command | Description |
|---------|-------------|
| `make help` | Show all available commands |
| `make aws-init` | Initialize Terraform backend |
| `make aws-plan` | Plan dev infrastructure |
| `make aws-apply` | Apply dev infrastructure |
| `make aws-destroy` | Destroy dev infrastructure |
| `make prod-plan` | Plan prod infrastructure |
| `make prod-apply` | Apply prod infrastructure |
| `make prod-destroy` | Destroy prod infrastructure |
| `make kong-deploy` | Deploy Kong (standalone) |
| `make clean` | Clean temp files |

### Environment Variables

```bash
export AWS_PROFILE=poc-eks     # AWS profile
export AWS_REGION=us-east-1    # AWS region
export ENVIRONMENT=dev         # Target environment
```

### Key URLs (After Deployment)

| Service | URL Pattern |
|---------|-------------|
| ArgoCD UI | `https://argocd.<domain>` or port-forward 8080 |
| Kong Proxy (dev) | NodePort via ALB |
| Kong Proxy (prod) | NLB DNS name |
| Kong Admin | ClusterIP (internal only) |
