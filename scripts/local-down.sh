#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CLUSTER_NAME="poc-eks-local"

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${RED}  POC EKS - Local Environment Teardown${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────
# Delete Cluster
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Deleting Kind cluster...${NC}"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    echo -e "${GREEN}✓ Cluster '${CLUSTER_NAME}' deleted${NC}"
else
    echo -e "${YELLOW}  Cluster '${CLUSTER_NAME}' not found${NC}"
fi

echo ""

# ─────────────────────────────────────────────────────────────────
# Clean up kubeconfig context
# ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▶ Cleaning up kubeconfig...${NC}"

CONTEXT_NAME="kind-${CLUSTER_NAME}"
if kubectl config get-contexts "${CONTEXT_NAME}" &>/dev/null; then
    kubectl config delete-context "${CONTEXT_NAME}" 2>/dev/null || true
    echo -e "${GREEN}✓ Context '${CONTEXT_NAME}' removed${NC}"
else
    echo -e "${YELLOW}  Context '${CONTEXT_NAME}' not found${NC}"
fi

# Remove cluster from kubeconfig
kubectl config delete-cluster "${CONTEXT_NAME}" 2>/dev/null || true

echo ""
echo -e "${GREEN}✓ Local environment cleaned up${NC}"
echo ""
