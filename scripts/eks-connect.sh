#!/bin/bash
# eks-connect.sh - Connect to private EKS cluster via SSM port forwarding
# Usage: ./scripts/eks-connect.sh <environment> [action]
# Actions: forward, bastion, kubeconfig, status

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
AWS_PROFILE="${AWS_PROFILE:-alm-yahoo-account}"
AWS_REGION="${AWS_REGION:-us-east-1}"
LOCAL_PORT="${LOCAL_PORT:-6443}"

# Validate arguments
ENVIRONMENT="${1:-}"
ACTION="${2:-forward}"

show_help() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  EKS Connect - Private Cluster Access via SSM${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Usage: $0 <environment> [action]"
    echo ""
    echo -e "${GREEN}Environments:${NC}"
    echo "  dev   - Development cluster"
    echo "  hom   - Homologation cluster"
    echo "  prod  - Production cluster"
    echo ""
    echo -e "${GREEN}Actions:${NC}"
    echo "  forward    - Start port forwarding (default)"
    echo "  bastion    - Connect directly to bastion via SSM"
    echo "  kubeconfig - Update kubeconfig for localhost access"
    echo "  status     - Show cluster and bastion status"
    echo ""
    echo -e "${GREEN}Environment Variables:${NC}"
    echo "  AWS_PROFILE  - AWS profile to use (default: alm-yahoo-account)"
    echo "  AWS_REGION   - AWS region (default: us-east-1)"
    echo "  LOCAL_PORT   - Local port for forwarding (default: 6443)"
    echo ""
    echo -e "${CYAN}Examples:${NC}"
    echo "  $0 dev forward      # Start port forwarding to dev cluster"
    echo "  $0 dev bastion      # Connect to dev bastion"
    echo "  $0 dev kubeconfig   # Configure kubectl for localhost:6443"
    echo ""
    echo -e "${CYAN}Workflow:${NC}"
    echo "  1. Terminal 1: $0 dev forward     # Keep running"
    echo "  2. Terminal 2: $0 dev kubeconfig  # Run once"
    echo "  3. Terminal 2: kubectl get nodes  # Use kubectl normally"
    echo ""
}

if [[ -z "$ENVIRONMENT" ]]; then
    show_help
    exit 1
fi

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|hom|prod)$ ]]; then
    echo -e "${RED}Error: Invalid environment '$ENVIRONMENT'. Use: dev, hom, or prod${NC}"
    exit 1
fi

# Set cluster name
CLUSTER_NAME="poc-eks-$ENVIRONMENT"

# Export AWS credentials
export AWS_PROFILE
export AWS_REGION

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  EKS Connect - $CLUSTER_NAME${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Environment:  ${GREEN}$ENVIRONMENT${NC}"
echo -e "  Action:       ${GREEN}$ACTION${NC}"
echo -e "  AWS Profile:  ${YELLOW}$AWS_PROFILE${NC}"
echo -e "  AWS Region:   ${YELLOW}$AWS_REGION${NC}"
echo ""

# Get bastion instance ID
get_bastion_id() {
    local bastion_id
    bastion_id=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=*${ENVIRONMENT}*bastion*" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null || echo "")
    
    if [[ -z "$bastion_id" || "$bastion_id" == "None" ]]; then
        # Try alternative tag pattern
        bastion_id=$(aws ec2 describe-instances \
            --filters "Name=tag:Name,Values=poc-eks-${ENVIRONMENT}-bastion" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null || echo "")
    fi
    
    echo "$bastion_id"
}

# Get cluster endpoint
get_cluster_endpoint() {
    aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --query 'cluster.endpoint' \
        --output text 2>/dev/null || echo ""
}

# Check if cluster exists
check_cluster() {
    if ! aws eks describe-cluster --name "$CLUSTER_NAME" &>/dev/null; then
        echo -e "${RED}Error: Cluster $CLUSTER_NAME not found${NC}"
        exit 1
    fi
}

# Start port forwarding
start_forward() {
    echo -e "${GREEN}▶ Starting port forwarding...${NC}"
    echo ""
    
    check_cluster
    
    local bastion_id
    bastion_id=$(get_bastion_id)
    
    if [[ -z "$bastion_id" || "$bastion_id" == "None" ]]; then
        echo -e "${RED}Error: Bastion host not found for environment '$ENVIRONMENT'${NC}"
        echo -e "${YELLOW}Make sure the bastion is running and tagged correctly${NC}"
        exit 1
    fi
    
    local endpoint
    endpoint=$(get_cluster_endpoint)
    
    if [[ -z "$endpoint" ]]; then
        echo -e "${RED}Error: Could not get cluster endpoint${NC}"
        exit 1
    fi
    
    # Remove https:// prefix
    local endpoint_host="${endpoint#https://}"
    
    echo -e "  Bastion ID:   ${CYAN}$bastion_id${NC}"
    echo -e "  EKS Endpoint: ${CYAN}$endpoint_host${NC}"
    echo -e "  Local Port:   ${CYAN}$LOCAL_PORT${NC}"
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Port forwarding active! Keep this terminal open.${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  In another terminal, run:"
    echo -e "    ${GREEN}$0 $ENVIRONMENT kubeconfig${NC}"
    echo -e "    ${GREEN}kubectl get nodes${NC}"
    echo ""
    echo -e "  Press ${RED}Ctrl+C${NC} to stop port forwarding"
    echo ""
    
    # Start SSM port forwarding
    aws ssm start-session \
        --target "$bastion_id" \
        --document-name AWS-StartPortForwardingSessionToRemoteHost \
        --parameters "{\"host\":[\"$endpoint_host\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}"
}

# Connect to bastion
connect_bastion() {
    echo -e "${GREEN}▶ Connecting to bastion...${NC}"
    echo ""
    
    local bastion_id
    bastion_id=$(get_bastion_id)
    
    if [[ -z "$bastion_id" || "$bastion_id" == "None" ]]; then
        echo -e "${RED}Error: Bastion host not found for environment '$ENVIRONMENT'${NC}"
        exit 1
    fi
    
    echo -e "  Bastion ID: ${CYAN}$bastion_id${NC}"
    echo ""
    echo -e "${YELLOW}Once connected, run:${NC}"
    echo -e "  ${GREEN}aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION${NC}"
    echo -e "  ${GREEN}kubectl get nodes${NC}"
    echo ""
    
    aws ssm start-session --target "$bastion_id"
}

# Configure kubeconfig for localhost
configure_kubeconfig() {
    echo -e "${GREEN}▶ Configuring kubeconfig for localhost access...${NC}"
    echo ""
    
    check_cluster
    
    # First, update kubeconfig with the real cluster
    aws eks update-kubeconfig \
        --name "$CLUSTER_NAME" \
        --alias "$CLUSTER_NAME-local"
    
    # Get the kubeconfig path
    local kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
    
    # Update the server URL to localhost
    if command -v yq &>/dev/null; then
        # Use yq if available (more reliable)
        yq -i "(.clusters[] | select(.name == \"*$CLUSTER_NAME*\") | .cluster.server) = \"https://localhost:$LOCAL_PORT\"" "$kubeconfig"
    elif command -v sed &>/dev/null; then
        # Fallback to sed
        local endpoint
        endpoint=$(get_cluster_endpoint)
        sed -i.bak "s|$endpoint|https://localhost:$LOCAL_PORT|g" "$kubeconfig"
        rm -f "${kubeconfig}.bak"
    fi
    
    echo ""
    echo -e "${GREEN}✓ kubeconfig updated!${NC}"
    echo ""
    echo -e "  Context:  ${CYAN}$CLUSTER_NAME-local${NC}"
    echo -e "  Server:   ${CYAN}https://localhost:$LOCAL_PORT${NC}"
    echo ""
    echo -e "${YELLOW}Make sure port forwarding is running in another terminal:${NC}"
    echo -e "  ${GREEN}$0 $ENVIRONMENT forward${NC}"
    echo ""
    echo -e "Then test with:"
    echo -e "  ${GREEN}kubectl get nodes${NC}"
    echo ""
    
    # Add insecure skip TLS verify (needed because cert is for the real endpoint)
    echo -e "${YELLOW}Note: You may need to add 'insecure-skip-tls-verify: true' to your kubeconfig${NC}"
    echo -e "      if you get certificate errors. This is safe for local dev.${NC}"
    echo ""
}

# Show status
show_status() {
    echo -e "${GREEN}▶ Cluster and Bastion Status${NC}"
    echo ""
    
    # Cluster status
    echo -e "${CYAN}Cluster: $CLUSTER_NAME${NC}"
    if aws eks describe-cluster --name "$CLUSTER_NAME" &>/dev/null; then
        aws eks describe-cluster \
            --name "$CLUSTER_NAME" \
            --query 'cluster.{Status:status,Version:version,Endpoint:endpoint,PublicAccess:resourcesVpcConfig.endpointPublicAccess,PrivateAccess:resourcesVpcConfig.endpointPrivateAccess}' \
            --output table
    else
        echo -e "  ${RED}Not found${NC}"
    fi
    
    echo ""
    
    # Bastion status
    echo -e "${CYAN}Bastion Host:${NC}"
    local bastion_id
    bastion_id=$(get_bastion_id)
    
    if [[ -n "$bastion_id" && "$bastion_id" != "None" ]]; then
        aws ec2 describe-instances \
            --instance-ids "$bastion_id" \
            --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,Type:InstanceType,PrivateIP:PrivateIpAddress}' \
            --output table
        
        echo ""
        echo -e "${CYAN}SSM Agent Status:${NC}"
        aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=$bastion_id" \
            --query 'InstanceInformationList[].{InstanceId:InstanceId,PingStatus:PingStatus,AgentVersion:AgentVersion}' \
            --output table 2>/dev/null || echo -e "  ${YELLOW}SSM agent not registered yet${NC}"
    else
        echo -e "  ${RED}Not found${NC}"
    fi
    
    echo ""
}

# Execute action
case "$ACTION" in
    forward)
        start_forward
        ;;
    bastion)
        connect_bastion
        ;;
    kubeconfig)
        configure_kubeconfig
        ;;
    status)
        show_status
        ;;
    *)
        echo -e "${RED}Error: Unknown action '$ACTION'${NC}"
        show_help
        exit 1
        ;;
esac
