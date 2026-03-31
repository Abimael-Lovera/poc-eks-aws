#!/bin/bash
# deploy.sh - Unified deployment script for EKS infrastructure
# Usage: ./scripts/deploy.sh <environment> [action]
# Environments: dev, hom, prod
# Actions: init, plan, apply, destroy, kubeconfig, status

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
AWS_PROFILE="${AWS_PROFILE:-alm-yahoo-account}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Validate arguments
ENVIRONMENT="${1:-}"
ACTION="${2:-apply}"

if [[ -z "$ENVIRONMENT" ]]; then
    echo -e "${RED}Error: Environment required${NC}"
    echo ""
    echo "Usage: $0 <environment> [action]"
    echo ""
    echo "Environments:"
    echo "  dev   - Development environment"
    echo "  hom   - Homologation/Staging environment"
    echo "  prod  - Production environment"
    echo ""
    echo "Actions:"
    echo "  init      - Initialize Terraform backend"
    echo "  plan      - Plan infrastructure changes"
    echo "  apply     - Apply infrastructure (default)"
    echo "  destroy   - Destroy infrastructure"
    echo "  kubeconfig - Configure kubectl for the cluster"
    echo "  status    - Show cluster and nodes status"
    echo ""
    echo "Example:"
    echo "  $0 dev apply"
    echo "  $0 hom plan"
    echo "  $0 prod kubeconfig"
    exit 1
fi

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|hom|prod)$ ]]; then
    echo -e "${RED}Error: Invalid environment '$ENVIRONMENT'. Use: dev, hom, or prod${NC}"
    exit 1
fi

# Set paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TF_DIR="$PROJECT_ROOT/infra/environments/$ENVIRONMENT"
STATE_DIR="$PROJECT_ROOT/infra/state"
CLUSTER_NAME="poc-eks-$ENVIRONMENT"

# Check if environment directory exists
if [[ ! -d "$TF_DIR" ]] && [[ "$ACTION" != "init" ]]; then
    echo -e "${RED}Error: Environment '$ENVIRONMENT' not found at $TF_DIR${NC}"
    echo -e "${YELLOW}Tip: Copy from dev environment or create the directory structure${NC}"
    exit 1
fi

# Export AWS credentials
export AWS_PROFILE
export AWS_REGION

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  POC EKS AWS - Deployment Script${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Environment:  ${GREEN}$ENVIRONMENT${NC}"
echo -e "  Action:       ${GREEN}$ACTION${NC}"
echo -e "  AWS Profile:  ${YELLOW}$AWS_PROFILE${NC}"
echo -e "  AWS Region:   ${YELLOW}$AWS_REGION${NC}"
echo -e "  Cluster:      ${YELLOW}$CLUSTER_NAME${NC}"
echo ""

# Functions
terraform_init() {
    echo -e "${GREEN}▶ Initializing Terraform...${NC}"
    cd "$TF_DIR"
    terraform init -backend-config="$STATE_DIR/backend.conf"
}

terraform_plan() {
    echo -e "${BLUE}▶ Planning infrastructure changes...${NC}"
    cd "$TF_DIR"
    terraform init -backend-config="$STATE_DIR/backend.conf" -input=false
    terraform plan -out=tfplan
}

terraform_apply() {
    echo -e "${GREEN}▶ Applying infrastructure...${NC}"
    cd "$TF_DIR"
    terraform init -backend-config="$STATE_DIR/backend.conf" -input=false
    
    if [[ -f "tfplan" ]]; then
        terraform apply tfplan
        rm -f tfplan
    else
        terraform apply
    fi
}

terraform_destroy() {
    echo -e "${RED}▶ Destroying infrastructure...${NC}"
    echo -e "${YELLOW}WARNING: This will destroy all resources in $ENVIRONMENT!${NC}"
    read -p "Type '$ENVIRONMENT' to confirm: " confirm
    
    if [[ "$confirm" != "$ENVIRONMENT" ]]; then
        echo -e "${RED}Destruction cancelled.${NC}"
        exit 1
    fi
    
    cd "$TF_DIR"
    terraform destroy
}

configure_kubeconfig() {
    echo -e "${GREEN}▶ Configuring kubectl for $CLUSTER_NAME...${NC}"
    
    # Check if cluster exists
    if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
        echo -e "${RED}Error: Cluster $CLUSTER_NAME not found${NC}"
        exit 1
    fi
    
    aws eks update-kubeconfig \
        --name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE"
    
    echo -e "${GREEN}✓ kubeconfig updated successfully${NC}"
    echo ""
    echo -e "${BLUE}Testing connection...${NC}"
    kubectl cluster-info
}

show_status() {
    echo -e "${BLUE}▶ Cluster Status${NC}"
    echo ""
    
    # Check if cluster exists
    if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
        echo -e "${RED}Cluster $CLUSTER_NAME not found${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Cluster Info:${NC}"
    aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
        --query 'cluster.{Name:name,Status:status,Version:version,Endpoint:endpoint}' \
        --output table
    
    echo ""
    echo -e "${GREEN}Node Groups:${NC}"
    aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
        --query 'nodegroups' --output table
    
    echo ""
    echo -e "${GREEN}Nodes (via kubectl):${NC}"
    kubectl get nodes -o wide 2>/dev/null || echo -e "${YELLOW}kubectl not configured for this cluster${NC}"
    
    echo ""
    echo -e "${GREEN}System Pods:${NC}"
    kubectl get pods -n kube-system 2>/dev/null || echo -e "${YELLOW}kubectl not configured for this cluster${NC}"
}

# Execute action
case "$ACTION" in
    init)
        terraform_init
        ;;
    plan)
        terraform_plan
        ;;
    apply)
        terraform_apply
        ;;
    destroy)
        terraform_destroy
        ;;
    kubeconfig)
        configure_kubeconfig
        ;;
    status)
        show_status
        ;;
    *)
        echo -e "${RED}Error: Unknown action '$ACTION'${NC}"
        echo "Valid actions: init, plan, apply, destroy, kubeconfig, status"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}✓ Done!${NC}"
