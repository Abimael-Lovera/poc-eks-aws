.PHONY: help local-up local-down aws-init aws-plan aws-apply aws-destroy kong-deploy kong-test clean

# Colors
BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m # No Color

# Variables
AWS_PROFILE ?= default
AWS_REGION ?= us-east-1
ENVIRONMENT ?= dev
CLUSTER_NAME ?= poc-eks-$(ENVIRONMENT)
TF_DIR := terraform/environments/$(ENVIRONMENT)
STATE_DIR := terraform/state

# Default target
help:
	@echo ""
	@echo "$(BLUE)═══════════════════════════════════════════════════════════════$(NC)"
	@echo "$(BLUE)  POC EKS AWS - Kubernetes Platform$(NC)"
	@echo "$(BLUE)═══════════════════════════════════════════════════════════════$(NC)"
	@echo ""
	@echo "$(GREEN)Local Environment:$(NC)"
	@echo "  make local-up      Create Kind cluster with Kong"
	@echo "  make local-down    Destroy Kind cluster"
	@echo "  make kong-test     Test Kong mock routes"
	@echo ""
	@echo "$(GREEN)AWS Infrastructure:$(NC)"
	@echo "  make aws-init      Initialize Terraform state backend"
	@echo "  make aws-plan      Plan AWS infrastructure changes"
	@echo "  make aws-apply     Apply AWS infrastructure"
	@echo "  make aws-destroy   Destroy AWS infrastructure"
	@echo ""
	@echo "$(GREEN)Deployment:$(NC)"
	@echo "  make kong-deploy   Deploy Kong to cluster"
	@echo ""
	@echo "$(GREEN)Utilities:$(NC)"
	@echo "  make clean         Clean temporary files"
	@echo ""
	@echo "$(YELLOW)Configuration:$(NC)"
	@echo "  AWS_PROFILE=$(AWS_PROFILE)"
	@echo "  AWS_REGION=$(AWS_REGION)"
	@echo "  ENVIRONMENT=$(ENVIRONMENT)"
	@echo ""

# ═══════════════════════════════════════════════════════════════
# Local Environment
# ═══════════════════════════════════════════════════════════════

local-up:
	@echo "$(GREEN)▶ Starting local Kubernetes cluster...$(NC)"
	@./scripts/local-up.sh

local-down:
	@echo "$(RED)▶ Destroying local Kubernetes cluster...$(NC)"
	@./scripts/local-down.sh

kong-test:
	@echo "$(BLUE)▶ Testing Kong mock routes...$(NC)"
	@echo ""
	@echo "Testing /health endpoint:"
	@curl -s http://localhost:8000/health | jq . || echo "Kong not running or jq not installed"
	@echo ""
	@echo "Testing /api/mock endpoint:"
	@curl -s http://localhost:8000/api/mock | jq . || echo "Kong not running or jq not installed"

# ═══════════════════════════════════════════════════════════════
# AWS Infrastructure
# ═══════════════════════════════════════════════════════════════

aws-init:
	@echo "$(GREEN)▶ Initializing Terraform state backend...$(NC)"
	@AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) ./scripts/aws-init.sh

aws-plan:
	@echo "$(BLUE)▶ Planning AWS infrastructure...$(NC)"
	@cd $(TF_DIR) && \
		AWS_PROFILE=$(AWS_PROFILE) terraform init && \
		AWS_PROFILE=$(AWS_PROFILE) terraform plan

aws-apply:
	@echo "$(GREEN)▶ Applying AWS infrastructure...$(NC)"
	@cd $(TF_DIR) && \
		AWS_PROFILE=$(AWS_PROFILE) terraform init && \
		AWS_PROFILE=$(AWS_PROFILE) terraform apply

aws-destroy:
	@echo "$(RED)▶ Destroying AWS infrastructure...$(NC)"
	@echo "$(YELLOW)WARNING: This will destroy all AWS resources!$(NC)"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	@cd $(TF_DIR) && \
		AWS_PROFILE=$(AWS_PROFILE) terraform destroy

# ═══════════════════════════════════════════════════════════════
# Deployment
# ═══════════════════════════════════════════════════════════════

kong-deploy:
	@echo "$(GREEN)▶ Deploying Kong...$(NC)"
	@./scripts/kong-deploy.sh $(ENVIRONMENT)

# ═══════════════════════════════════════════════════════════════
# Utilities
# ═══════════════════════════════════════════════════════════════

clean:
	@echo "$(YELLOW)▶ Cleaning temporary files...$(NC)"
	@find . -name "*.tfplan" -delete
	@find . -name ".terraform.lock.hcl" -delete
	@echo "$(GREEN)✓ Clean complete$(NC)"
