#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CLUSTER_NAME="poc-eks-local"
KIND_CONFIG="kubernetes/local/kind-config.yaml"
KONG_VALUES="helm/values/kong/local.yaml"
KONG_NAMESPACE="kong"

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  POC EKS - Local Environment Setup${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────
# Prerequisites Check
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Checking prerequisites...${NC}"

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}✗ $1 is not installed${NC}"
        echo "  Please install $1 before continuing"
        exit 1
    fi
    echo -e "${GREEN}✓ $1 found${NC}"
}

check_command "kind"
check_command "kubectl"
check_command "helm"

# Check if OrbStack or Docker is running
if command -v orbctl &> /dev/null; then
    if ! orbctl status &> /dev/null; then
        echo -e "${RED}✗ OrbStack is not running${NC}"
        echo "  Please start OrbStack before continuing"
        exit 1
    fi
    echo -e "${GREEN}✓ OrbStack is running${NC}"
elif command -v docker &> /dev/null; then
    if ! docker info &> /dev/null 2>&1; then
        echo -e "${RED}✗ Docker is not running${NC}"
        echo "  Please start Docker before continuing"
        exit 1
    fi
    echo -e "${GREEN}✓ Docker is running${NC}"
else
    echo -e "${RED}✗ Neither OrbStack nor Docker found${NC}"
    exit 1
fi

echo ""

# ─────────────────────────────────────────────────────────────────
# Cluster Creation
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Creating Kind cluster...${NC}"

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo -e "${YELLOW}  Cluster '${CLUSTER_NAME}' already exists${NC}"
    read -p "  Do you want to delete and recreate it? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kind delete cluster --name "${CLUSTER_NAME}"
    else
        echo -e "${BLUE}  Using existing cluster${NC}"
    fi
fi

# Create cluster if it doesn't exist
if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    kind create cluster --config "${KIND_CONFIG}"
    echo -e "${GREEN}✓ Cluster created${NC}"
else
    echo -e "${GREEN}✓ Cluster ready${NC}"
fi

echo ""

# ─────────────────────────────────────────────────────────────────
# Wait for Nodes
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Waiting for nodes to be ready...${NC}"

kubectl wait --for=condition=Ready nodes --all --timeout=120s
echo -e "${GREEN}✓ All nodes ready${NC}"

echo ""

# ─────────────────────────────────────────────────────────────────
# Install Kong
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Installing Kong API Gateway...${NC}"

# Add Kong Helm repo
helm repo add kong https://charts.konghq.com 2>/dev/null || true
helm repo update

# Create namespace
kubectl create namespace "${KONG_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Install Kong
helm upgrade --install kong kong/ingress \
    --namespace "${KONG_NAMESPACE}" \
    --values "${KONG_VALUES}" \
    --wait \
    --timeout 5m

echo -e "${GREEN}✓ Kong installed${NC}"

echo ""

# ─────────────────────────────────────────────────────────────────
# Apply Mock Routes
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Applying mock routes...${NC}"

# Apply only YAML files (skip kustomization.yaml which needs kubectl apply -k)
kubectl apply -f apps/kong/base/mock-routes.yaml

echo -e "${GREEN}✓ Mock routes applied${NC}"

echo ""

# ─────────────────────────────────────────────────────────────────
# Wait for Kong to be ready
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Waiting for Kong to be ready...${NC}"

kubectl wait --for=condition=Available deployment/kong-gateway \
    --namespace "${KONG_NAMESPACE}" \
    --timeout=120s 2>/dev/null || \
kubectl wait --for=condition=Available deployment/kong-kong \
    --namespace "${KONG_NAMESPACE}" \
    --timeout=120s 2>/dev/null || \
echo -e "${YELLOW}  Kong deployment name may vary, continuing...${NC}"

# Give it a few seconds to stabilize
sleep 5

echo -e "${GREEN}✓ Kong is ready${NC}"

echo ""

# ─────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Local environment is ready!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Cluster Info:${NC}"
echo "  Name:    ${CLUSTER_NAME}"
echo "  Nodes:   $(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
echo ""
echo -e "${BLUE}Kong Endpoints:${NC}"
echo "  Proxy:   http://localhost:8000"
echo "  Admin:   http://localhost:8001"
echo ""
echo -e "${BLUE}Test Commands:${NC}"
echo "  curl http://localhost:8000/health"
echo "  curl http://localhost:8000/api/mock"
echo ""
echo -e "${BLUE}Useful Commands:${NC}"
echo "  kubectl get pods -n kong"
echo "  kubectl get svc -n kong"
echo "  make kong-test"
echo ""
