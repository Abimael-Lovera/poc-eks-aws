# EKS Cluster Connection Guide

This guide explains how to connect to the EKS clusters deployed by this project.

## Prerequisites

1. **AWS CLI v2** installed and configured
2. **kubectl** installed (v1.28+)
3. **AWS credentials** with access to the EKS cluster

```bash
# Verify AWS CLI
aws --version

# Verify kubectl
kubectl version --client
```

## Quick Start

### Using the Deploy Script

The easiest way to configure kubectl:

```bash
# For dev environment
./scripts/deploy.sh dev kubeconfig

# For hom (homologation) environment
./scripts/deploy.sh hom kubeconfig

# For prod environment
./scripts/deploy.sh prod kubeconfig
```

### Manual Configuration

```bash
# Set your AWS profile
export AWS_PROFILE=alm-yahoo-account
export AWS_REGION=us-east-1

# Update kubeconfig for dev cluster
aws eks update-kubeconfig \
  --name poc-eks-dev \
  --region us-east-1 \
  --profile alm-yahoo-account

# Verify connection
kubectl cluster-info
kubectl get nodes
```

## Cluster Details

| Environment | Cluster Name    | Region    |
|-------------|-----------------|-----------|
| dev         | poc-eks-dev     | us-east-1 |
| hom         | poc-eks-hom     | us-east-1 |
| prod        | poc-eks-prod    | us-east-1 |

## Accessing via Bastion Host

For secure access from within the VPC, use the bastion host:

### Via AWS Session Manager (Recommended)

No SSH keys required - uses IAM authentication:

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
```

Once connected to the bastion:

```bash
# Configure kubectl (on bastion)
aws eks update-kubeconfig --name poc-eks-dev --region us-east-1

# Verify
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

### "Unauthorized" Error

```bash
# Verify your AWS identity
aws sts get-caller-identity --profile alm-yahoo-account

# Re-authenticate
aws eks update-kubeconfig --name poc-eks-dev --region us-east-1 --profile alm-yahoo-account
```

### Nodes Not Ready

```bash
# Check node status
kubectl describe nodes

# Check kube-system pods
kubectl get pods -n kube-system

# Check VPC CNI
kubectl logs -n kube-system -l k8s-app=aws-node
```

### SSM Connection Failed

```bash
# Check if SSM agent is registered
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$BASTION_ID" \
  --profile alm-yahoo-account \
  --region us-east-1

# If empty, wait 5 minutes after instance launch for agent to register
```

### Cannot Pull Images

This usually means nodes don't have egress to ECR. Check:
- NAT Gateway is running
- Security group allows egress on port 443
- Route table has 0.0.0.0/0 → NAT Gateway

## Security Notes

1. **Never commit kubeconfig** - It's in `.gitignore`
2. **Use SSM over SSH** - No exposed ports, IAM-based auth
3. **Rotate credentials** - AWS tokens expire, refresh with `update-kubeconfig`
4. **Least privilege** - Only grant necessary K8s RBAC permissions

## Additional Resources

- [EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/)
- [kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/)
- [AWS SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
