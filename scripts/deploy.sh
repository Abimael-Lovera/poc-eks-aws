#!/bin/bash
# deploy.sh - Unified deployment script for EKS infrastructure
# Usage: ./scripts/deploy.sh <environment> [action]
# Environments: dev, hom, prod
# Actions: init, plan, apply, destroy, kubeconfig, status, base, addons

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
SSM_PID=""
LOCAL_PORT="6443"

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
    echo "  apply     - Apply infrastructure (auto two-phase for private clusters)"
    echo "  base      - Deploy only base infrastructure (no Helm addons)"
    echo "  addons    - Deploy only Helm addons (requires SSM tunnel for private clusters)"
    echo "  destroy   - Destroy infrastructure"
    echo "  kubeconfig - Configure kubectl for the cluster"
    echo "  status    - Show cluster and nodes status"
    echo ""
    echo "Example:"
    echo "  $0 dev apply      # Full deploy with auto SSM tunnel if needed"
    echo "  $0 dev base       # Phase 1 only (no Helm)"
    echo "  $0 dev addons     # Phase 2 only (Helm via tunnel)"
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

# ─────────────────────────────────────────────────────────────────────────────
# SSM Tunnel Functions (for private cluster access)
# ─────────────────────────────────────────────────────────────────────────────

# Check if cluster has private-only endpoint
is_cluster_private_only() {
    local public_access
    public_access=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --query 'cluster.resourcesVpcConfig.endpointPublicAccess' \
        --output text \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" 2>/dev/null)
    
    [[ "$public_access" == "False" ]]
}

# Start SSM tunnel in background for private cluster access
start_ssm_tunnel() {
    local bastion_id
    bastion_id=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${CLUSTER_NAME}-bastion" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" 2>/dev/null)
    
    if [[ -z "$bastion_id" || "$bastion_id" == "None" ]]; then
        echo -e "${RED}ERROR: Bastion instance not found or not running${NC}"
        return 1
    fi
    
    local cluster_endpoint
    cluster_endpoint=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --query 'cluster.endpoint' \
        --output text \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" 2>/dev/null | sed 's|https://||')
    
    echo -e "  ${BLUE}Starting SSM tunnel: localhost:$LOCAL_PORT → $cluster_endpoint:443${NC}"
    echo -e "  ${BLUE}Bastion ID: $bastion_id${NC}"
    
    aws ssm start-session \
        --target "$bastion_id" \
        --document-name AWS-StartPortForwardingSessionToRemoteHost \
        --parameters "{\"host\":[\"$cluster_endpoint\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" > /dev/null 2>&1 &
    
    SSM_PID=$!
    echo -e "  ${BLUE}SSM tunnel PID: $SSM_PID${NC}"
    
    # Wait for tunnel to be ready
    echo -e "  ${YELLOW}Waiting for tunnel to establish...${NC}"
    sleep 8
    
    # Verify tunnel is working
    if ! kill -0 $SSM_PID 2>/dev/null; then
        echo -e "${RED}ERROR: SSM tunnel failed to start${NC}"
        return 1
    fi
    
    echo -e "  ${GREEN}✓ SSM tunnel established${NC}"
}

# Stop SSM tunnel
stop_ssm_tunnel() {
    if [[ -n "$SSM_PID" ]] && kill -0 $SSM_PID 2>/dev/null; then
        echo -e "  ${BLUE}Stopping SSM tunnel (PID: $SSM_PID)...${NC}"
        kill $SSM_PID 2>/dev/null || true
        wait $SSM_PID 2>/dev/null || true
        SSM_PID=""
    fi
}

# Cleanup on exit
cleanup() {
    stop_ssm_tunnel
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Terraform Functions
# ─────────────────────────────────────────────────────────────────────────────

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

# Deploy base infrastructure only (no Helm addons)
terraform_apply_base() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Phase 1: Deploying base infrastructure (no Helm addons)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    cd "$TF_DIR"
    terraform init -backend-config="$STATE_DIR/backend.conf" -input=false
    terraform apply -var="deploy_helm_addons=false" -auto-approve
    
    echo ""
    echo -e "${GREEN}✓ Phase 1 complete. Base infrastructure deployed.${NC}"
}

# Deploy Helm addons only (with SSM tunnel if private)
terraform_apply_addons() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Phase 2: Deploying Helm addons${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    cd "$TF_DIR"
    
    # Check if cluster is private-only
    if is_cluster_private_only; then
        echo -e "  ${YELLOW}Cluster is private-only. Starting SSM tunnel...${NC}"
        
        if ! start_ssm_tunnel; then
            echo -e "${RED}ERROR: Failed to start SSM tunnel. Cannot deploy Helm addons.${NC}"
            echo -e "${YELLOW}TIP: You can start the tunnel manually and retry:${NC}"
            echo -e "${YELLOW}  1. In another terminal: ./scripts/eks-connect.sh $ENVIRONMENT forward${NC}"
            echo -e "${YELLOW}  2. Then run: $0 $ENVIRONMENT addons${NC}"
            return 1
        fi
        
        # Deploy with localhost endpoint override
        terraform init -backend-config="$STATE_DIR/backend.conf" -input=false
        terraform apply \
            -var="deploy_helm_addons=true" \
            -var="kubernetes_host_override=https://localhost:$LOCAL_PORT" \
            -auto-approve
        
        stop_ssm_tunnel
    else
        echo -e "  ${GREEN}Cluster has public access. Deploying directly...${NC}"
        terraform init -backend-config="$STATE_DIR/backend.conf" -input=false
        terraform apply -var="deploy_helm_addons=true" -auto-approve
    fi
    
    echo ""
    echo -e "${GREEN}✓ Phase 2 complete. Helm addons deployed.${NC}"
}

# Full apply (two phases for private clusters)
terraform_apply() {
    # Check if cluster already exists
    if aws eks describe-cluster --name "$CLUSTER_NAME" --profile "$AWS_PROFILE" --region "$AWS_REGION" &>/dev/null; then
        echo -e "${BLUE}▶ Cluster exists. Running full apply...${NC}"
        
        # If cluster is private, we need two-phase
        if is_cluster_private_only; then
            terraform_apply_base
            terraform_apply_addons
        else
            # Public cluster - single apply
            cd "$TF_DIR"
            terraform init -backend-config="$STATE_DIR/backend.conf" -input=false
            terraform apply -auto-approve
        fi
    else
        # First deployment - must do two phases
        echo -e "${BLUE}▶ First deployment. Running two-phase deploy...${NC}"
        terraform_apply_base
        
        # Wait a bit for cluster to be fully ready
        echo -e "${YELLOW}Waiting for cluster to stabilize...${NC}"
        sleep 10
        
        terraform_apply_addons
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
    terraform init -backend-config="$STATE_DIR/backend.conf" -input=false
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
    
    # Check if private
    if is_cluster_private_only; then
        echo -e "${YELLOW}NOTE: This is a private cluster. To access it:${NC}"
        echo -e "${YELLOW}  1. Start SSM tunnel: ./scripts/eks-connect.sh $ENVIRONMENT forward${NC}"
        echo -e "${YELLOW}  2. Then use kubectl normally${NC}"
    else
        echo -e "${BLUE}Testing connection...${NC}"
        kubectl cluster-info
    fi
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
    
    # Show endpoint access
    local public_access private_access
    public_access=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
        --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text)
    private_access=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
        --query 'cluster.resourcesVpcConfig.endpointPrivateAccess' --output text)
    
    echo ""
    echo -e "${GREEN}Endpoint Access:${NC}"
    echo -e "  Public:  $public_access"
    echo -e "  Private: $private_access"
    
    echo ""
    echo -e "${GREEN}Node Groups:${NC}"
    aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
        --query 'nodegroups' --output table
    
    echo ""
    echo -e "${GREEN}Nodes (via kubectl):${NC}"
    kubectl get nodes -o wide 2>/dev/null || echo -e "${YELLOW}kubectl not configured or cluster not reachable${NC}"
    
    echo ""
    echo -e "${GREEN}System Pods:${NC}"
    kubectl get pods -n kube-system 2>/dev/null || echo -e "${YELLOW}kubectl not configured or cluster not reachable${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Execute Action
# ─────────────────────────────────────────────────────────────────────────────

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
    base)
        terraform_apply_base
        ;;
    addons)
        terraform_apply_addons
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
        echo "Valid actions: init, plan, apply, base, addons, destroy, kubeconfig, status"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}✓ Done!${NC}"
