# POC EKS AWS

Production-ready Kubernetes platform on AWS EKS with Kong API Gateway, ArgoCD GitOps, and Flagger canary deployments.

## Overview

This POC implements **Propuesta A (IP Mode)** from the [Kong HA Architecture Proposal](docs/PROPOSAL-KONG-HA-ARCHITECTURE.md):

- **Kong API Gateway** in DB-less mode with configuration via CRDs
- **IP Mode** for ALB: direct traffic to pod IPs (lower latency, pod-level health checks)
- **ElastiCache Redis Multi-AZ** for distributed rate limiting
- **ArgoCD** for GitOps-based deployments
- **Flagger** for progressive canary releases

## Architecture

```
                           ┌─────────────┐
                           │   ArgoCD    │ ── GitOps sync
                           └──────┬──────┘
                                  │
┌─────────────────────────────────┼─────────────────────────────────┐
│                            AWS VPC                                 │
│                                                                    │
│   ┌──────────────┐         ┌───┴───┐         ┌──────────────┐    │
│   │     ALB      │────────▶│ Kong  │────────▶│   Backend    │    │
│   │  (IP Mode)   │         │  Pods │         │   Services   │    │
│   └──────────────┘         └───┬───┘         └──────────────┘    │
│                                │                                   │
│   Traffic: ALB → Pod IP        │              ┌──────────────┐    │
│   Latency: ~1-2ms              └─────────────▶│ ElastiCache  │    │
│                                               │    Redis     │    │
│   ┌──────────────┐                           └──────────────┘    │
│   │  Karpenter   │ ── Dynamic node scaling                        │
│   └──────────────┘                                                │
└───────────────────────────────────────────────────────────────────┘
```

**IP Mode vs Instance Mode:**

| Aspect | IP Mode (Prod) | Instance Mode (Dev) |
|--------|---------------|---------------------|
| Traffic path | ALB → Pod IP | NLB → NodePort → Pod |
| Latency | ~1-2ms | ~3-5ms |
| Health checks | Pod-level | Node-level |
| VPC IP usage | 1 IP per pod | Minimal |

## Directory Structure

```
poc-eks-aws/
├── terraform/                 # Infrastructure as Code
│   ├── modules/               # Reusable Terraform modules
│   │   ├── vpc/               # VPC, subnets, NAT gateway
│   │   ├── eks/               # EKS cluster configuration
│   │   ├── bastion/           # Bastion host (SSM access)
│   │   ├── alb-controller/    # AWS Load Balancer Controller
│   │   ├── karpenter/         # Node autoscaling
│   │   └── elasticache/       # Redis for rate limiting
│   ├── environments/          # Environment-specific configs
│   │   ├── dev/               # Development environment
│   │   └── prod/              # Production environment
│   └── state/                 # S3 backend configuration
│
├── helm/values/kong/          # Kong Helm values per environment
│   ├── base.yaml              # Shared configuration
│   ├── local.yaml             # Kind cluster (local dev)
│   ├── dev.yaml               # Dev environment
│   ├── staging.yaml           # Staging environment
│   └── prod.yaml              # Production environment
│
├── argocd/                    # ArgoCD GitOps manifests
│   ├── bootstrap/             # ArgoCD installation
│   ├── projects/              # ArgoCD projects (RBAC)
│   └── applicationsets/       # Multi-env app definitions
│
├── canary/                    # Flagger canary configurations
│   └── kong-canary.yaml       # Kong canary deployment
│
├── apps/kong/                 # Kong Kustomize overlays
├── kubernetes/                # K8s manifests (local/aws)
├── scripts/                   # Automation scripts
├── docs/                      # Architecture documentation
│   ├── adr/                   # Architecture Decision Records
│   └── PROPOSAL-KONG-HA-ARCHITECTURE.md
└── Makefile                   # Task runner
```

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| AWS CLI | >= 2.x | AWS authentication |
| Terraform | >= 1.0 | Infrastructure provisioning |
| kubectl | >= 1.28 | Kubernetes management |
| Helm | >= 3.x | Package management |
| kind | >= 0.20 | Local Kubernetes (optional) |

## Quick Start

### Local Development

```bash
# Start local Kind cluster with Kong
make local-up

# Test mock endpoints
curl http://localhost:8000/health
curl http://localhost:8000/api/mock

# Stop cluster
make local-down
```

### AWS Development Environment

```bash
# Configure AWS credentials
export AWS_PROFILE=your-profile

# Initialize Terraform backend (one-time)
make aws-init

# Plan and review changes
make aws-plan

# Apply infrastructure
make aws-apply

# Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name poc-eks-dev

# Deploy Kong
make kong-deploy ENVIRONMENT=dev

# Destroy when done
make aws-destroy
```

### AWS Production Environment

```bash
# Plan prod changes
make prod-plan

# Apply prod infrastructure
make prod-apply

# Deploy Kong to prod
make kong-deploy ENVIRONMENT=prod

# Destroy prod (requires confirmation)
make prod-destroy
```

## Environments

| Environment | ALB Mode | Redis | NAT Gateway | Autosync | Use Case |
|-------------|----------|-------|-------------|----------|----------|
| **local** | N/A | In-memory | N/A | N/A | Local development |
| **dev** | Instance | Sentinel (K8s) | Single | Auto | Feature testing |
| **staging** | IP | ElastiCache | Single | Manual | Pre-prod validation |
| **prod** | IP | ElastiCache Multi-AZ | Per AZ | Manual + CR | Production traffic |

## Make Commands

### Local

| Command | Description |
|---------|-------------|
| `make local-up` | Create Kind cluster with Kong |
| `make local-down` | Destroy Kind cluster |
| `make kong-test` | Test Kong mock routes |

### AWS (Dev)

| Command | Description |
|---------|-------------|
| `make aws-init` | Initialize Terraform state backend |
| `make aws-plan` | Plan infrastructure changes |
| `make aws-apply` | Apply infrastructure |
| `make aws-destroy` | Destroy all resources |

### AWS (Prod)

| Command | Description |
|---------|-------------|
| `make prod-init` | Initialize Terraform for prod |
| `make prod-plan` | Plan prod changes |
| `make prod-apply` | Apply prod infrastructure |
| `make prod-destroy` | Destroy prod (requires confirmation) |

### Deployment

| Command | Description |
|---------|-------------|
| `make kong-deploy ENVIRONMENT=<env>` | Deploy Kong to specified environment |
| `make clean` | Clean temporary files |

## Configuration

### Environment Variables

```bash
export AWS_PROFILE=your-profile    # AWS credentials profile
export AWS_REGION=us-east-1        # Target region
export ENVIRONMENT=dev             # Environment (dev/staging/prod)
```

### Terraform Variables

Edit `terraform/environments/<env>/terraform.tfvars`:

```hcl
aws_region  = "us-east-1"
environment = "dev"

# VPC
vpc_cidr           = "10.0.0.0/16"
az_count           = 2
single_nat_gateway = true          # false for prod HA

# EKS
cluster_version            = "1.33"
system_node_instance_types = ["t3.medium"]
```

## Documentation

- [Kong HA Architecture Proposal](docs/PROPOSAL-KONG-HA-ARCHITECTURE.md) - Full architecture design
- [Architecture Decision Records](docs/adr/) - Design decisions

## Security

- **Bastion**: Session Manager access (no SSH keys required)
- **IMDSv2**: Required on all instances
- **EBS**: Encrypted volumes
- **S3**: Versioning + encryption for Terraform state
- **IAM**: IRSA for pod-level permissions
- **Pod Readiness Gates**: ALB waits for pod readiness in IP mode

## License

MIT
