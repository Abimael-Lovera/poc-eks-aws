# EKS Cluster Connection Guide

This guide explains how to connect to the EKS clusters deployed by this project.

## Architecture

The EKS clusters are configured with **private endpoint only** for security. This means:

- ❌ No direct access from internet
- ✅ Access only from within the VPC (bastion, VPN, or port forwarding)

```
┌──────────────────────────────────────────────────────────────┐
│                      YOUR MACHINE                             │
│                                                               │
│  Terminal 1:                    Terminal 2:                   │
│  ┌─────────────────────┐       ┌─────────────────────┐       │
│  │ eks-connect.sh      │       │ kubectl get nodes   │       │
│  │ dev forward         │       │                     │       │
│  │                     │       │ → localhost:6443    │       │
│  │ (SSM Port Forward)  │◄──────┤                     │       │
│  └─────────────────────┘       └─────────────────────┘       │
│           │                                                   │
└───────────┼───────────────────────────────────────────────────┘
            │ SSM Tunnel (encrypted)
            ▼
┌──────────────────────────────────────────────────────────────┐
│                         AWS VPC                               │
│                                                               │
│  ┌─────────────┐              ┌─────────────────────────┐    │
│  │   BASTION   │─────────────►│   EKS API (Private)     │    │
│  │   (SSM)     │   port 443   │   https://xxx.eks...    │    │
│  └─────────────┘              └─────────────────────────┘    │
│                                           │                   │
│                               ┌───────────┴───────────┐      │
│                               │   WORKER NODES        │      │
│                               │   (Bottlerocket)      │      │
│                               └───────────────────────┘      │
└──────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **AWS CLI v2** installed and configured
2. **Session Manager Plugin** for AWS CLI
3. **kubectl** installed (v1.28+)
4. **AWS credentials** with access to the EKS cluster

```bash
# Verify AWS CLI
aws --version

# Install Session Manager Plugin (macOS)
brew install --cask session-manager-plugin

# Verify kubectl
kubectl version --client
```

## Quick Start (Recommended)

### Option A: Port Forwarding from Your Machine

Use this to work with kubectl from your local IDE/terminal:

```bash
# Terminal 1 - Start port forwarding (keep running)
./scripts/eks-connect.sh dev forward

# Terminal 2 - Configure kubectl and use it
./scripts/eks-connect.sh dev kubeconfig
kubectl get nodes
```

### Option B: Work Directly on Bastion

Use this for quick operations or if port forwarding has issues:

```bash
# Connect to bastion
./scripts/eks-connect.sh dev bastion

# Once connected (inside bastion):
aws eks update-kubeconfig --name poc-eks-dev --region us-east-1
kubectl get nodes
```

## Cluster Details

| Environment | Cluster Name    | Region    | Endpoint |
|-------------|-----------------|-----------|----------|
| dev         | poc-eks-dev     | us-east-1 | Private  |
| hom         | poc-eks-hom     | us-east-1 | Private  |
| prod        | poc-eks-prod    | us-east-1 | Private  |

## eks-connect.sh Reference

The `eks-connect.sh` script provides all connection methods:

| Command | Description |
|---------|-------------|
| `./scripts/eks-connect.sh dev forward` | Start SSM port forwarding to EKS API |
| `./scripts/eks-connect.sh dev bastion` | Connect directly to bastion via SSM |
| `./scripts/eks-connect.sh dev kubeconfig` | Configure kubectl for localhost:6443 |
| `./scripts/eks-connect.sh dev status` | Show cluster and bastion status |

### Environment Variables

```bash
export AWS_PROFILE=alm-yahoo-account  # AWS profile (default)
export AWS_REGION=us-east-1           # AWS region (default)
export LOCAL_PORT=6443                # Local port for forwarding (default)
```

### Full Workflow Example

```bash
# 1. Check status first
./scripts/eks-connect.sh dev status

# 2. Start port forwarding (Terminal 1 - keep open)
./scripts/eks-connect.sh dev forward

# 3. Configure kubectl (Terminal 2 - run once)
./scripts/eks-connect.sh dev kubeconfig

# 4. Use kubectl normally (Terminal 2)
kubectl get nodes
kubectl get pods -A
kubectl logs -n kube-system -l k8s-app=kube-dns
```

## Manual Connection Methods

### SSM Port Forwarding (Manual)

If you prefer not to use the script:

```bash
# Get bastion instance ID
BASTION_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*bastion*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text \
  --profile alm-yahoo-account \
  --region us-east-1)

# Get cluster endpoint
ENDPOINT=$(aws eks describe-cluster \
  --name poc-eks-dev \
  --query 'cluster.endpoint' \
  --output text \
  --profile alm-yahoo-account \
  --region us-east-1)

# Start port forwarding
aws ssm start-session \
  --target $BASTION_ID \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${ENDPOINT#https://}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"6443\"]}" \
  --profile alm-yahoo-account \
  --region us-east-1
```

### Direct Bastion Connection (Manual)

```bash
# Get bastion instance ID
BASTION_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*bastion*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text \
  --profile alm-yahoo-account \
  --region us-east-1)

# Connect via SSM
aws ssm start-session --target $BASTION_ID --profile alm-yahoo-account --region us-east-1

# Once connected to the bastion:
aws eks update-kubeconfig --name poc-eks-dev --region us-east-1
kubectl get nodes
```

### Via SSH (If Configured)

If SSH key was configured during deployment:

```bash
# Get bastion public IP
BASTION_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*bastion*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --profile alm-yahoo-account \
  --region us-east-1)

# Connect via SSH
ssh -i ~/.ssh/your-key.pem ec2-user@$BASTION_IP
```

## Common Operations

### Check Cluster Status

```bash
./scripts/eks-connect.sh dev status
# or
./scripts/deploy.sh dev status
```

### View All Pods

```bash
kubectl get pods -A
```

### View System Components

```bash
kubectl get pods -n kube-system
```

### View Nodes

```bash
kubectl get nodes -o wide
```

### View Cluster Events

```bash
kubectl get events -A --sort-by='.lastTimestamp'
```

## Deploying Applications

### Deploy Kong Gateway

```bash
# Must have kubectl access first
make kong-deploy ENVIRONMENT=dev
```

### Using Helm

```bash
# Add a Helm repo
helm repo add bitnami https://charts.bitnami.com/bitnami

# Install a chart
helm install my-release bitnami/nginx -n default
```

## Troubleshooting

### Port Forwarding Not Working

```bash
# 1. Check bastion status
./scripts/eks-connect.sh dev status

# 2. Verify SSM agent is registered
aws ssm describe-instance-information \
  --profile alm-yahoo-account \
  --region us-east-1

# 3. If empty, the bastion may need a few minutes after boot
#    or check if it has internet access (NAT Gateway)
```

### Certificate Errors with localhost

When using port forwarding, you may see certificate errors because the EKS certificate is for the real endpoint, not localhost.

**Solution**: Add `insecure-skip-tls-verify` to your kubeconfig:

```bash
# Edit ~/.kube/config and add under the cluster:
clusters:
- cluster:
    insecure-skip-tls-verify: true  # Add this line
    server: https://localhost:6443
  name: poc-eks-dev-local
```

### "Unauthorized" Error

```bash
# Verify your AWS identity
aws sts get-caller-identity --profile alm-yahoo-account

# Re-authenticate
./scripts/eks-connect.sh dev kubeconfig
```

### Connection Refused on localhost:6443

```bash
# Make sure port forwarding is running in Terminal 1
./scripts/eks-connect.sh dev forward

# Check if something else is using port 6443
lsof -i :6443

# Use a different port if needed
LOCAL_PORT=16443 ./scripts/eks-connect.sh dev forward
```

### Nodes Not Ready

```bash
# Check node status
kubectl describe nodes

# Check kube-system pods
kubectl get pods -n kube-system

# Check VPC CNI logs
kubectl logs -n kube-system -l k8s-app=aws-node
```

### SSM Connection Failed

```bash
# Check if SSM agent is registered
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$BASTION_ID" \
  --profile alm-yahoo-account \
  --region us-east-1

# If empty:
# - Wait 5 minutes after instance launch for agent to register
# - Check bastion has internet access (NAT Gateway)
# - Check bastion IAM role has SSM permissions
```

### Cannot Pull Images

This usually means nodes don't have egress to ECR. Check:

- NAT Gateway is running
- Security group allows egress on port 443
- Route table has 0.0.0.0/0 → NAT Gateway

## Security Notes

1. **Private endpoint only** - No direct internet access to EKS API
2. **SSM over SSH** - No exposed ports, IAM-based authentication
3. **Never commit kubeconfig** - It's in `.gitignore`
4. **Rotate credentials** - AWS tokens expire, refresh with `update-kubeconfig`
5. **Least privilege** - Only grant necessary K8s RBAC permissions
6. **Bastion access** - All cluster access is auditable via SSM logs

## Additional Resources

- [EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/)
- [kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/)
- [AWS SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [EKS Private Cluster Access](https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html)
