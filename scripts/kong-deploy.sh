#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ENVIRONMENT="${1:-local}"
KONG_NAMESPACE="kong"
VALUES_FILE="helm/values/kong/${ENVIRONMENT}.yaml"

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Kong Deployment - ${ENVIRONMENT}${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────
# Validate Environment
# ─────────────────────────────────────────────────────────────────
if [ ! -f "${VALUES_FILE}" ]; then
    echo -e "${RED}✗ Values file not found: ${VALUES_FILE}${NC}"
    echo "  Available environments: local, aws"
    exit 1
fi

echo -e "${YELLOW}▶ Environment: ${ENVIRONMENT}${NC}"
echo -e "${YELLOW}  Values file: ${VALUES_FILE}${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────
# Check kubectl connection
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Checking cluster connection...${NC}"

if ! kubectl cluster-info &>/dev/null; then
    echo -e "${RED}✗ Cannot connect to Kubernetes cluster${NC}"
    echo "  Please configure kubectl first"
    exit 1
fi

CLUSTER_NAME=$(kubectl config current-context)
echo -e "${GREEN}✓ Connected to: ${CLUSTER_NAME}${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────
# Add Helm repo
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Updating Helm repos...${NC}"
helm repo add kong https://charts.konghq.com 2>/dev/null || true
helm repo update
echo -e "${GREEN}✓ Helm repos updated${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────
# Create namespace
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Creating namespace...${NC}"
kubectl create namespace "${KONG_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespace '${KONG_NAMESPACE}' ready${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────
# Deploy Kong
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Deploying Kong...${NC}"

helm upgrade --install kong kong/ingress \
    --namespace "${KONG_NAMESPACE}" \
    --values "${VALUES_FILE}" \
    --wait \
    --timeout 10m

echo -e "${GREEN}✓ Kong deployed${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────
# Apply mock routes
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Applying mock routes...${NC}"

if [ -d "apps/kong/overlays/${ENVIRONMENT}" ]; then
    kubectl apply -k "apps/kong/overlays/${ENVIRONMENT}"
else
    kubectl apply -f apps/kong/base/
fi

echo -e "${GREEN}✓ Mock routes applied${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────
# Wait and show status
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Waiting for Kong to be ready...${NC}"
sleep 5

kubectl get pods -n "${KONG_NAMESPACE}"
echo ""
kubectl get svc -n "${KONG_NAMESPACE}"

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Kong deployment complete!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [ "${ENVIRONMENT}" = "local" ]; then
    echo -e "${BLUE}Test locally:${NC}"
    echo "  curl http://localhost:8000/health"
    echo "  curl http://localhost:8000/api/mock"
else
    echo -e "${BLUE}Get ALB endpoint:${NC}"
    echo "  kubectl get ingress -n ${KONG_NAMESPACE}"
fi
echo ""
