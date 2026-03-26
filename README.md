# POC EKS AWS

Kubernetes platform with local development (Kind + OrbStack) and AWS production (EKS + Karpenter + ALB).

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        LOCAL (Kind)                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │ Control     │    │   Worker    │    │   Worker    │         │
│  │   Plane     │    │    Node     │    │    Node     │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│         │                  │                  │                  │
│         └──────────────────┴──────────────────┘                  │
│                            │                                     │
│                     ┌──────┴──────┐                              │
│                     │    Kong     │                              │
│                     │   Gateway   │                              │
│                     └──────┬──────┘                              │
│                            │                                     │
│                    localhost:8000                                │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                         AWS (EKS)                                │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                         VPC                              │    │
│  │  ┌─────────────┐                    ┌─────────────┐     │    │
│  │  │   Public    │                    │   Private   │     │    │
│  │  │   Subnet    │                    │   Subnet    │     │    │
│  │  │  ┌───────┐  │                    │  ┌───────┐  │     │    │
│  │  │  │Bastion│  │                    │  │  EKS  │  │     │    │
│  │  │  └───────┘  │                    │  │ Nodes │  │     │    │
│  │  │  ┌───────┐  │   ──NodePort──▶    │  └───────┘  │     │    │
│  │  │  │  ALB  │  │                    │  ┌───────┐  │     │    │
│  │  │  └───────┘  │                    │  │Karpen-│  │     │    │
│  │  │             │                    │  │  ter  │  │     │    │
│  │  └─────────────┘                    │  └───────┘  │     │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- **Local**: kind, kubectl, helm, OrbStack (or Docker)
- **AWS**: AWS CLI, Terraform >= 1.0, valid AWS credentials

### Local Environment

```bash
# Start local cluster with Kong
make local-up

# Test mock routes
curl http://localhost:8000/health
curl http://localhost:8000/api/mock

# Stop local cluster
make local-down
```

### AWS Environment

```bash
# 1. Configure AWS profile
export AWS_PROFILE=your-profile

# 2. Initialize Terraform state backend (one-time)
make aws-init

# 3. Plan infrastructure
make aws-plan

# 4. Apply infrastructure
make aws-apply

# 5. Connect to bastion (via Session Manager)
aws ssm start-session --target <instance-id>

# 6. Configure kubectl (from bastion or local)
aws eks update-kubeconfig --region us-east-1 --name poc-eks-dev

# 7. Deploy Kong to EKS
make kong-deploy ENVIRONMENT=aws

# Destroy when done
make aws-destroy
```

## Project Structure

```
poc-eks-aws/
├── apps/                          # Application configs
│   └── kong/
│       ├── base/                  # Base Kustomize
│       └── overlays/              # Environment overlays
│
├── terraform/                     # Infrastructure as Code
│   ├── modules/                   # Reusable modules
│   │   ├── vpc/                   # VPC + subnets
│   │   ├── eks/                   # EKS cluster
│   │   ├── bastion/               # Bastion host
│   │   ├── alb-controller/        # AWS LB Controller
│   │   └── karpenter/             # Node autoscaling
│   ├── environments/              # Environment configs
│   │   └── dev/
│   └── state/                     # Backend config
│
├── kubernetes/                    # K8s manifests
│   ├── local/                     # Kind config
│   └── aws/                       # EKS-specific (Karpenter)
│
├── helm/                          # Helm values
│   └── values/
│       └── kong/
│
├── scripts/                       # Automation
│   ├── local-up.sh
│   ├── local-down.sh
│   ├── aws-init.sh
│   └── kong-deploy.sh
│
├── Makefile                       # Task runner
└── README.md
```

## Configuration

### Environment Variables

```bash
# Required for AWS
export AWS_PROFILE=your-profile    # AWS credentials profile
export AWS_REGION=us-east-1        # Target region

# Optional
export ENVIRONMENT=dev             # Environment name (default: dev)
```

### Terraform Variables

Edit `terraform/environments/dev/terraform.tfvars`:

```hcl
aws_region  = "us-east-1"
environment = "dev"

# VPC
vpc_cidr           = "10.0.0.0/16"
az_count           = 2
single_nat_gateway = true

# EKS
cluster_version            = "1.33"
system_node_instance_types = ["t3.medium"]

# Bastion
bastion_instance_type = "t3.micro"
```

## Make Targets

| Target | Description |
|--------|-------------|
| `make help` | Show all available commands |
| `make local-up` | Create Kind cluster with Kong |
| `make local-down` | Destroy Kind cluster |
| `make kong-test` | Test Kong mock routes |
| `make aws-init` | Initialize Terraform backend |
| `make aws-plan` | Plan AWS infrastructure |
| `make aws-apply` | Apply AWS infrastructure |
| `make aws-destroy` | Destroy AWS infrastructure |
| `make kong-deploy` | Deploy Kong to current cluster |

## Kong Mock Routes

| Endpoint | Response |
|----------|----------|
| `GET /health` | `{"status": "healthy", ...}` |
| `GET /api/mock` | `{"status": "ok", "message": "mock response", ...}` |
| `GET /api/echo` | Echo request info |

## AWS Components

### Networking
- **VPC**: 10.0.0.0/16 with 2 AZs
- **Public Subnets**: Bastion, NAT Gateway, ALB
- **Private Subnets**: EKS nodes, pods

### Compute
- **EKS**: Kubernetes 1.33
- **System Nodes**: t3.medium (managed node group)
- **Karpenter Nodes**: t3.medium/large/xlarge (spot preferred)
- **Bastion**: t3.micro (free tier)

### Load Balancing
- **ALB**: Instance mode (routes to NodePorts 30000-32767)
- **NLB**: Optional for TCP/UDP workloads

### Autoscaling
- **Karpenter**: Dynamic node provisioning
- **Limits**: 100 vCPU, 200Gi memory max

## Security

- **Bastion**: Session Manager access (no SSH keys)
- **IMDSv2**: Required on all instances
- **EBS**: Encrypted volumes
- **S3**: Versioning + encryption for TF state
- **IAM**: IRSA for pod-level permissions

## Cost Optimization

- Single NAT Gateway in dev (set `single_nat_gateway = false` for prod HA)
- Spot instances for Karpenter nodes
- t3.micro bastion (free tier)
- Karpenter limits prevent runaway scaling

## Troubleshooting

### Local cluster won't start
```bash
# Check OrbStack/Docker is running
orbctl status  # or docker info

# Delete and recreate
kind delete cluster --name poc-eks-local
make local-up
```

### Cannot connect to EKS
```bash
# Update kubeconfig
aws eks update-kubeconfig --region us-east-1 --name poc-eks-dev

# Verify
kubectl get nodes
```

### ALB not routing traffic
```bash
# Check ALB Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Verify security groups allow NodePort range (30000-32767)
```

### Karpenter not provisioning nodes
```bash
# Check Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter

# Verify NodePool and EC2NodeClass
kubectl get nodepools
kubectl get ec2nodeclasses
```

## License

MIT
