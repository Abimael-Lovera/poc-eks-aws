# Proposal: Project Structure Refactor

**Change Name:** `project-structure-refactor`  
**Date:** 2026-03-29  
**Status:** Draft  
**Author:** Platform Team  

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current State](#2-current-state)
3. [Proposed Structure](#3-proposed-structure)
   - 3.1 [High-Level Organization](#31-high-level-organization)
   - 3.2 [Full Directory Tree](#32-full-directory-tree)
   - 3.3 [Explanation of Each Area](#33-explanation-of-each-area)
   - 3.4 [Module Interface Design Principles](#34-module-interface-design-principles)
   - 3.5 [Module Interface Examples](#35-module-interface-examples)
4. [Migration Strategy](#4-migration-strategy)
5. [Terraform State Migration](#5-terraform-state-migration)
6. [IAM Least Privilege Design](#6-iam-least-privilege-design)
7. [Risks and Mitigations](#7-risks-and-mitigations)
8. [Rollback Plan](#8-rollback-plan)
9. [Success Criteria](#9-success-criteria)
10. [Timeline Estimate](#10-timeline-estimate)

---

## 1. Executive Summary

### What We're Changing

This proposal restructures the POC EKS AWS project from a flat, mixed-concern layout into a clean three-folder architecture that separates infrastructure code from deployment manifests and documentation.

### Why We're Changing It

| Problem | Impact | Solution |
|---------|--------|----------|
| IAM scattered across 3 modules | Hard to audit, review, and maintain security posture | Dedicated security module with JSON policies |
| ALB policy downloaded at runtime | Not auditable, version controlled, or reviewable | Commit policies as JSON files in repo |
| Circular dependency EKS ↔ ALB | `alb_security_group_id = null` hack, broken SG rules | Security module creates SGs first |
| K8s manifests at root level | 5 top-level folders for deployment concerns | Consolidate under `deploy/` |
| AWS managed policies for Karpenter | Over-permissioned, not least-privilege | Custom policies with minimal permissions |
| No clear separation of concerns | Terraform and K8s manifests interleaved | `infra/` vs `deploy/` separation |

### Key Benefits

1. **Security Auditability**: All IAM policies in JSON files, version controlled, PR reviewable
2. **Clean Architecture**: Clear separation between infrastructure and deployment
3. **Maintainability**: EKS addons as submodules within compute/eks
4. **Dependency Resolution**: No more circular dependencies or null hacks
5. **Least Privilege**: Custom policies replace overly-permissive AWS managed policies

---

## 2. Current State

### Current Directory Structure

```
poc-eks-aws/
├── terraform/                        # Infrastructure (mixed concerns)
│   ├── modules/
│   │   ├── alb-controller/          # IAM + SG + Helm (mixed)
│   │   ├── bastion/                 # IAM + SG + EC2 (mixed)
│   │   ├── eks/                     # EKS cluster only
│   │   ├── elasticache/             # Redis + SG (mixed)
│   │   ├── karpenter/               # IAM + Helm + SQS (mixed)
│   │   └── vpc/                     # Networking
│   ├── environments/
│   │   ├── dev/
│   │   └── prod/
│   └── state/
├── argocd/                          # GitOps manifests (root level)
├── apps/                            # Kustomize overlays (root level)
├── canary/                          # Flagger config (root level)
├── helm/                            # Helm values (root level)
├── kubernetes/                      # K8s manifests (root level)
├── docs/
├── scripts/
├── Makefile
└── README.md
```

### Problems with Current Approach

#### 2.1 IAM Scattered Across Multiple Modules

| Module | IAM Resources | Trust Policy | Problem |
|--------|--------------|--------------|---------|
| `alb-controller` | IRSA role, policy | EKS OIDC | Policy downloaded from GitHub at runtime |
| `karpenter` | IRSA role, node role, instance profile | EKS OIDC, EC2 | Uses AWS managed policies (over-permissive) |
| `bastion` | EC2 role, instance profile | EC2 | Inline policy hard to audit |

**Current ALB Controller Policy Source (PROBLEM):**
```hcl
# terraform/modules/alb-controller/main.tf:22-24
data "http" "alb_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json"
}
```

This is **not auditable** - the policy is fetched at `terraform apply` time and never committed to source control.

#### 2.2 Circular Dependency (EKS ↔ ALB)

```
┌─────────────────────────────────────────────────────────────┐
│                    CIRCULAR DEPENDENCY                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   EKS Module                    ALB Controller Module        │
│   ┌──────────────┐              ┌──────────────────┐        │
│   │ Needs:       │              │ Creates:         │        │
│   │ ALB SG ID    │◄─────────────│ ALB Security     │        │
│   │ (for node SG │              │ Group            │        │
│   │  rule)       │              │                  │        │
│   │              │              │ Needs:           │        │
│   │ Creates:     │──────────────►│ EKS OIDC ARN    │        │
│   │ OIDC Provider│              │ (for IRSA)      │        │
│   └──────────────┘              └──────────────────┘        │
│                                                              │
│   CURRENT HACK: alb_security_group_id = null                │
│   RESULT: SG rule in EKS module doesn't work                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**Evidence from `terraform/environments/dev/main.tf:144`:**
```hcl
# ALB security group for NodePort access (placeholder - updated after ALB module)
alb_security_group_id = null
```

The SG rule in EKS module (`node_security_group_additional_rules`) is configured but **never applied** because the SG ID is null. A workaround exists at line 206-213 but it's outside module boundaries.

#### 2.3 Kubernetes Manifests at Root Level

**5 separate folders** at root for deployment concerns:

| Folder | Contents | Should Be |
|--------|----------|-----------|
| `argocd/` | ArgoCD bootstrap, projects, applicationsets | `deploy/argocd/` |
| `apps/` | Kustomize base and overlays for Kong | `deploy/apps/` |
| `canary/` | Flagger canary definition | `deploy/canary/` |
| `helm/` | Helm values per environment | `deploy/helm/` |
| `kubernetes/` | K8s manifests (Karpenter NodePool, Kind config) | `deploy/kubernetes/` |

#### 2.4 AWS Managed Policies (Over-Permissive)

**Karpenter Node Role (`terraform/modules/karpenter/main.tf:65-70`):**
```hcl
custom_role_policy_arns = [
  "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
  "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
  "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
]
```

These AWS managed policies contain **more permissions than needed**. For example:
- `AmazonEKSWorkerNodePolicy` allows `ec2:Describe*` on all resources
- `AmazonSSMManagedInstanceCore` allows SSM session access (may not be needed for worker nodes)

---

## 3. Proposed Structure

### 3.1 High-Level Organization

```
poc-eks-aws/
├── infra/                           # ALL Terraform infrastructure
├── deploy/                          # ALL Kubernetes/GitOps manifests
├── docs/                            # Documentation (unchanged)
├── scripts/                         # Automation scripts
├── Makefile                         # Task runner
└── README.md                        # Project overview
```

### 3.2 Full Directory Tree

```
poc-eks-aws/
│
├── infra/                                    # ALL Terraform code
│   │
│   ├── modules/
│   │   │
│   │   ├── networking/
│   │   │   └── vpc/
│   │   │       ├── main.tf
│   │   │       ├── variables.tf
│   │   │       └── outputs.tf
│   │   │
│   │   ├── security/                         # NEW: Dedicated security module
│   │   │   │
│   │   │   ├── iam/
│   │   │   │   ├── main.tf                   # Role definitions
│   │   │   │   ├── variables.tf
│   │   │   │   ├── outputs.tf
│   │   │   │   └── policies/                 # JSON policy files
│   │   │   │       ├── alb-controller.json
│   │   │   │       ├── karpenter-controller.json
│   │   │   │       ├── karpenter-node.json
│   │   │   │       └── bastion-eks-access.json
│   │   │   │
│   │   │   └── security-groups/
│   │   │       ├── main.tf                   # All SG definitions
│   │   │       ├── variables.tf
│   │   │       └── outputs.tf
│   │   │
│   │   ├── compute/
│   │   │   │
│   │   │   ├── eks/
│   │   │   │   ├── cluster/                  # Core EKS cluster
│   │   │   │   │   ├── main.tf
│   │   │   │   │   ├── variables.tf
│   │   │   │   │   └── outputs.tf
│   │   │   │   │
│   │   │   │   └── addons/                   # EKS addons as submodules
│   │   │   │       │
│   │   │   │       ├── alb-controller/
│   │   │   │       │   ├── main.tf           # Helm chart only
│   │   │   │       │   ├── variables.tf
│   │   │   │       │   └── outputs.tf
│   │   │   │       │
│   │   │   │       └── karpenter/
│   │   │   │           ├── main.tf           # Helm + SQS + EventBridge
│   │   │   │           ├── variables.tf
│   │   │   │           └── outputs.tf
│   │   │   │
│   │   │   └── bastion/
│   │   │       ├── main.tf                   # EC2 only (no IAM/SG)
│   │   │       ├── variables.tf
│   │   │       └── outputs.tf
│   │   │
│   │   └── data/
│   │       └── elasticache/
│   │           ├── main.tf                   # Redis only (no SG)
│   │           ├── variables.tf
│   │           └── outputs.tf
│   │
│   ├── environments/
│   │   ├── dev/
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   ├── outputs.tf
│   │   │   └── terraform.tfvars
│   │   │
│   │   └── prod/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── terraform.tfvars
│   │
│   └── state/
│       └── backend.tf
│
├── deploy/                                   # ALL deployment manifests
│   │
│   ├── argocd/
│   │   ├── bootstrap/
│   │   │   └── argocd-install.yaml
│   │   ├── projects/
│   │   │   └── kong-project.yaml
│   │   └── applicationsets/
│   │       ├── kong-gateway.yaml
│   │       └── flagger.yaml
│   │
│   ├── helm/
│   │   └── values/
│   │       └── kong/
│   │           ├── base.yaml
│   │           ├── local.yaml
│   │           ├── dev.yaml
│   │           ├── staging.yaml
│   │           ├── prod.yaml
│   │           └── aws.yaml
│   │
│   ├── kubernetes/
│   │   ├── aws/
│   │   │   └── karpenter-nodepool.yaml
│   │   └── local/
│   │       └── kind-config.yaml
│   │
│   ├── apps/
│   │   └── kong/
│   │       ├── base/
│   │       │   ├── kustomization.yaml
│   │       │   └── mock-routes.yaml
│   │       └── overlays/
│   │
│   └── canary/
│       └── kong-canary.yaml
│
├── docs/
│   ├── adr/
│   │   ├── ADR-001-*.md
│   │   ├── ADR-002-*.md
│   │   ├── ADR-003-*.md
│   │   └── ADR-004-*.md
│   ├── proposals/
│   │   └── PROPOSAL-PROJECT-STRUCTURE-REFACTOR.md
│   ├── DEPLOYMENT-GUIDE.md
│   └── PROPOSAL-KONG-HA-ARCHITECTURE.md
│
├── scripts/
│   ├── deploy-argocd.sh
│   ├── local-setup.sh
│   ├── state-migration.sh              # NEW: State migration helper
│   └── validate-iam.sh                 # NEW: IAM policy validator
│
├── Makefile
└── README.md
```

### 3.3 Explanation of Each Area

#### `infra/` - Infrastructure as Code

All Terraform code lives here. Organized by concern:

| Path | Purpose |
|------|---------|
| `infra/modules/networking/vpc/` | VPC, subnets, NAT gateways, route tables |
| `infra/modules/security/iam/` | **All IAM roles, policies, instance profiles** |
| `infra/modules/security/security-groups/` | **All security groups (ALB, bastion, elasticache, EKS additional)** |
| `infra/modules/compute/eks/cluster/` | Core EKS cluster, managed node groups, addons |
| `infra/modules/compute/eks/addons/alb-controller/` | ALB Controller Helm chart (receives IAM ARN as input) |
| `infra/modules/compute/eks/addons/karpenter/` | Karpenter Helm + SQS + EventBridge (receives IAM ARNs as input) |
| `infra/modules/compute/bastion/` | Bastion EC2 instance (receives IAM/SG as input) |
| `infra/modules/data/elasticache/` | ElastiCache Redis (receives SG as input) |
| `infra/environments/dev/` | Dev environment wiring |
| `infra/environments/prod/` | Prod environment wiring |

#### `deploy/` - Kubernetes & GitOps

All deployment manifests consolidated:

| Path | Purpose |
|------|---------|
| `deploy/argocd/` | ArgoCD installation, projects, applicationsets |
| `deploy/helm/` | Helm values for all charts (Kong, etc.) |
| `deploy/kubernetes/` | Raw K8s manifests (Karpenter NodePool, Kind config) |
| `deploy/apps/` | Kustomize bases and overlays |
| `deploy/canary/` | Flagger canary definitions |

#### `docs/` - Documentation

Unchanged structure, documentation stays at root level for visibility.

---

### 3.4 Module Interface Design Principles

**Core Principle: "In main.tf I only call 3 modules: vpc, iam, eks. I control WHAT gets created by passing parameters, not by calling sub-modules."**

The environment `main.tf` is the **source of truth**. It explicitly declares:
- Which IAM roles to create (and their policies)
- Which EKS addons to enable
- What VPC configuration to use

Modules are **generic and reusable** — they don't contain business logic about what to create. The caller decides.

#### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **IAM module receives role definitions as a map** | Caller explicitly defines what roles exist, their trust policies, and permission policies |
| **EKS module receives addon flags** | Simple boolean flags to enable/disable. Internal submodules are hidden from caller |
| **Policies live in environment folder** | `environments/dev/policies/*.json` — version controlled, PR reviewable, environment-specific |
| **No circular dependencies** | Two-phase IAM approach handles OIDC chicken-egg problem |

---

### 3.5 Module Interface Examples

#### 3.5.1 VPC Module Interface

The VPC module is the simplest — straightforward inputs, no complex logic.

```hcl
# environments/dev/main.tf

module "vpc" {
  source = "../../modules/networking/vpc"
  
  project_name = var.project_name
  environment  = var.environment
  
  vpc_cidr             = "10.0.0.0/16"
  availability_zones   = ["us-east-1a", "us-east-1b", "us-east-1c"]
  
  # Simple flag: /23 subnets for IP mode (more IPs), /24 for instance mode
  use_large_subnets = var.environment == "prod"
}
```

**Outputs used by other modules:**
- `module.vpc.vpc_id`
- `module.vpc.private_subnet_ids`
- `module.vpc.public_subnet_ids`

---

#### 3.5.2 IAM Module Interface

**The user defines exactly which roles to create.** The module doesn't decide — the caller does.

Policies are JSON files stored in the environment folder: `environments/dev/policies/`

```
environments/dev/
├── main.tf
├── variables.tf
├── outputs.tf
├── terraform.tfvars
└── policies/
    ├── trust/
    │   ├── eks-cluster.json      # Trust policy for EKS cluster role
    │   ├── ec2.json              # Trust policy for EC2 roles
    │   └── irsa.json.tpl         # Template for IRSA trust policies
    ├── eks-cluster.json          # EKS cluster permissions
    ├── alb-controller.json       # ALB controller permissions
    ├── karpenter-controller.json # Karpenter controller permissions
    ├── karpenter-node.json       # Karpenter node permissions
    └── bastion.json              # Bastion host permissions
```

**IAM Module Call (Two-Phase Approach):**

```hcl
# environments/dev/main.tf

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1: Base IAM Roles (no OIDC dependency)
# ─────────────────────────────────────────────────────────────────────────────
# These roles don't need EKS OIDC provider, so they can be created first.

module "iam_base" {
  source = "../../modules/security/iam"
  
  project_name = var.project_name
  environment  = var.environment
  
  # User defines exactly what roles to create
  roles = {
    eks_cluster = {
      description  = "EKS Cluster Role"
      trust_policy = file("${path.module}/policies/trust/eks-cluster.json")
      policy_files = [
        "${path.module}/policies/eks-cluster.json"
      ]
    }
    
    karpenter_node = {
      description  = "Karpenter Node Role"
      trust_policy = file("${path.module}/policies/trust/ec2.json")
      policy_files = [
        "${path.module}/policies/karpenter-node.json"
      ]
      # Optional: create instance profile for EC2 roles
      create_instance_profile = true
    }
    
    bastion = {
      description  = "Bastion Host Role"
      trust_policy = file("${path.module}/policies/trust/ec2.json")
      policy_files = [
        "${path.module}/policies/bastion.json"
      ]
      create_instance_profile = true
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2: EKS Cluster (needs base IAM, outputs OIDC)
# ─────────────────────────────────────────────────────────────────────────────

module "eks" {
  source = "../../modules/compute/eks"
  # ... see EKS section below
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3: IRSA Roles (needs OIDC provider ARN from EKS)
# ─────────────────────────────────────────────────────────────────────────────
# These roles use OIDC federation, so they must be created AFTER EKS.

module "iam_irsa" {
  source = "../../modules/security/iam"
  
  project_name = var.project_name
  environment  = var.environment
  
  # OIDC provider for IRSA trust policies
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  
  roles = {
    alb_controller = {
      description = "ALB Controller IRSA Role"
      trust_policy = templatefile("${path.module}/policies/trust/irsa.json.tpl", {
        oidc_provider_arn = module.eks.oidc_provider_arn
        oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")
        namespace         = "kube-system"
        service_account   = "aws-load-balancer-controller"
      })
      policy_files = [
        "${path.module}/policies/alb-controller.json"
      ]
    }
    
    karpenter_controller = {
      description = "Karpenter Controller IRSA Role"
      trust_policy = templatefile("${path.module}/policies/trust/irsa.json.tpl", {
        oidc_provider_arn = module.eks.oidc_provider_arn
        oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")
        namespace         = "karpenter"
        service_account   = "karpenter"
      })
      policy_files = [
        "${path.module}/policies/karpenter-controller.json"
      ]
    }
    
    external_dns = {
      description = "External DNS IRSA Role"
      trust_policy = templatefile("${path.module}/policies/trust/irsa.json.tpl", {
        oidc_provider_arn = module.eks.oidc_provider_arn
        oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")
        namespace         = "external-dns"
        service_account   = "external-dns"
      })
      policy_files = [
        "${path.module}/policies/external-dns.json"
      ]
    }
  }
  
  depends_on = [module.eks]
}
```

**IRSA Trust Policy Template (`policies/trust/irsa.json.tpl`):**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${oidc_provider_arn}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${oidc_provider_url}:sub": "system:serviceaccount:${namespace}:${service_account}",
          "${oidc_provider_url}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

**IAM Module Outputs:**

```hcl
# Access roles by name
module.iam_base.roles["eks_cluster"].arn
module.iam_base.roles["eks_cluster"].name
module.iam_base.roles["karpenter_node"].instance_profile_name

module.iam_irsa.roles["alb_controller"].arn
module.iam_irsa.roles["karpenter_controller"].arn
```

---

#### 3.5.3 EKS Module Interface

**User passes flags to enable/disable addons.** ALL addons are internal submodules — user never calls them directly.

```hcl
# environments/dev/main.tf

module "eks" {
  source = "../../modules/compute/eks"
  
  cluster_name    = "${var.project_name}-${var.environment}"
  cluster_version = "1.33"
  
  # Network configuration
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids
  
  # IAM role for the cluster itself (from base IAM)
  cluster_role_arn = module.iam_base.roles["eks_cluster"].arn
  
  # ─────────────────────────────────────────────────────────────────────────
  # ADDONS: Simple flags to enable/disable
  # ─────────────────────────────────────────────────────────────────────────
  # The EKS module handles all the complexity internally.
  # User just says "I want ALB controller" = true.
  
  addons = {
    # AWS native EKS addons
    coredns            = true
    kube_proxy         = true
    vpc_cni            = true
    pod_identity_agent = true
    
    # Helm-based addons (managed internally by EKS module)
    alb_controller = true                                    # Always enabled
    karpenter      = var.environment == "prod" ? true : false # Only in prod
    metrics_server = true
  }
  
  # ─────────────────────────────────────────────────────────────────────────
  # IAM ROLE ARNs: Passed from IAM modules
  # ─────────────────────────────────────────────────────────────────────────
  # EKS module doesn't create IAM — it receives ARNs.
  
  iam_role_arns = {
    alb_controller       = module.iam_irsa.roles["alb_controller"].arn
    karpenter_controller = try(module.iam_irsa.roles["karpenter_controller"].arn, null)
    karpenter_node       = try(module.iam_base.roles["karpenter_node"].arn, null)
    karpenter_instance_profile = try(module.iam_base.roles["karpenter_node"].instance_profile_name, null)
  }
  
  # ─────────────────────────────────────────────────────────────────────────
  # ADDON CONFIGURATION: Optional overrides (only if you need them)
  # ─────────────────────────────────────────────────────────────────────────
  
  alb_controller_config = {
    chart_version       = "1.7.1"
    default_target_type = var.environment == "prod" ? "ip" : "instance"
    # ip mode: ENI directly attached (requires VPC CNI, more IPs)
    # instance mode: NodePort (works everywhere)
  }
  
  karpenter_config = {
    chart_version = "1.0.1"
    # Karpenter NodePool and EC2NodeClass are K8s resources in deploy/kubernetes/
  }
  
  tags = local.tags
  
  depends_on = [module.iam_irsa]
}
```

**What happens internally in the EKS module:**

```
modules/compute/eks/
├── main.tf              # Core cluster, managed node groups
├── variables.tf         # All inputs including addons map
├── outputs.tf           # cluster_endpoint, oidc_provider_arn, etc.
└── addons/
    ├── coredns.tf       # EKS addon: coredns
    ├── kube-proxy.tf    # EKS addon: kube-proxy  
    ├── vpc-cni.tf       # EKS addon: vpc-cni
    ├── alb-controller/  # Helm chart (internal submodule)
    │   └── main.tf
    └── karpenter/       # Helm + SQS + EventBridge (internal submodule)
        └── main.tf
```

The user NEVER calls `module.eks.addons.alb_controller` — they just set `addons.alb_controller = true`.

**EKS Module Outputs:**

```hcl
module.eks.cluster_endpoint
module.eks.cluster_certificate_authority_data
module.eks.oidc_provider_arn
module.eks.oidc_provider_url
module.eks.node_security_group_id
```

---

#### 3.5.4 Complete Environment main.tf Example

Here's how it all comes together — the full picture:

```hcl
# environments/dev/main.tf

terraform {
  required_version = ">= 1.5"
  
  backend "s3" {
    bucket = "poc-eks-terraform-state"
    key    = "dev/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  cluster_name = "${var.project_name}-${var.environment}"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. VPC (no dependencies)
# ─────────────────────────────────────────────────────────────────────────────

module "vpc" {
  source = "../../modules/networking/vpc"
  
  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = "10.0.0.0/16"
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
  use_large_subnets  = false  # /24 for dev, /23 for prod
  
  tags = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. BASE IAM (no OIDC dependency)
# ─────────────────────────────────────────────────────────────────────────────

module "iam_base" {
  source = "../../modules/security/iam"
  
  project_name = var.project_name
  environment  = var.environment
  
  roles = {
    eks_cluster = {
      description  = "EKS Cluster Role"
      trust_policy = file("${path.module}/policies/trust/eks-cluster.json")
      policy_files = ["${path.module}/policies/eks-cluster.json"]
    }
    karpenter_node = {
      description             = "Karpenter Node Role"
      trust_policy            = file("${path.module}/policies/trust/ec2.json")
      policy_files            = ["${path.module}/policies/karpenter-node.json"]
      create_instance_profile = true
    }
    bastion = {
      description             = "Bastion Host Role"
      trust_policy            = file("${path.module}/policies/trust/ec2.json")
      policy_files            = ["${path.module}/policies/bastion.json"]
      create_instance_profile = true
    }
  }
  
  tags = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. EKS CLUSTER (needs VPC + base IAM, outputs OIDC)
# ─────────────────────────────────────────────────────────────────────────────

module "eks" {
  source = "../../modules/compute/eks"
  
  cluster_name     = local.cluster_name
  cluster_version  = "1.33"
  cluster_role_arn = module.iam_base.roles["eks_cluster"].arn
  
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids
  
  # Addons enabled/disabled via flags
  addons = {
    coredns            = true
    kube_proxy         = true
    vpc_cni            = true
    pod_identity_agent = true
    alb_controller     = true
    karpenter          = false  # Disabled in dev
    metrics_server     = true
  }
  
  # Terraform resolves the dependency graph automatically:
  # 1. EKS cluster creates first → exports OIDC
  # 2. iam_irsa uses OIDC → creates IRSA roles  
  # 3. EKS addons (internal resources) wait for the ARN values
  # No circular dependency because EKS module separates cluster creation from addon installation.
  iam_role_arns = {
    alb_controller             = module.iam_irsa.roles["alb_controller"].arn
    karpenter_controller       = module.iam_irsa.roles["karpenter_controller"].arn
    karpenter_node             = module.iam_base.roles["karpenter_node"].arn
    karpenter_instance_profile = module.iam_base.roles["karpenter_node"].instance_profile_name
  }
  
  alb_controller_config = {
    chart_version       = "1.7.1"
    default_target_type = "instance"
  }
  
  tags = local.tags
  
  depends_on = [module.iam_base, module.vpc]
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. IRSA ROLES (needs OIDC from EKS)
# ─────────────────────────────────────────────────────────────────────────────

module "iam_irsa" {
  source = "../../modules/security/iam"
  
  project_name      = var.project_name
  environment       = var.environment
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  
  roles = {
    alb_controller = {
      description = "ALB Controller IRSA Role"
      trust_policy = templatefile("${path.module}/policies/trust/irsa.json.tpl", {
        oidc_provider_arn = module.eks.oidc_provider_arn
        oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")
        namespace         = "kube-system"
        service_account   = "aws-load-balancer-controller"
      })
      policy_files = ["${path.module}/policies/alb-controller.json"]
    }
  }
  
  tags = local.tags
  
  depends_on = [module.eks]
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. BASTION (needs IAM + VPC)
# ─────────────────────────────────────────────────────────────────────────────

module "bastion" {
  source = "../../modules/compute/bastion"
  
  name                      = "${local.cluster_name}-bastion"
  vpc_id                    = module.vpc.vpc_id
  subnet_id                 = module.vpc.public_subnet_ids[0]
  iam_instance_profile_name = module.iam_base.roles["bastion"].instance_profile_name
  
  cluster_name     = local.cluster_name
  cluster_endpoint = module.eks.cluster_endpoint
  
  tags = local.tags
  
  depends_on = [module.eks]
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────────────────────────────────────────

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_name" {
  value = local.cluster_name
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}
```

---

#### 3.5.5 Handling the OIDC Chicken-Egg Problem

Since IRSA roles need the OIDC provider ARN (from EKS), but some approaches require EKS to have the role ARNs at creation time, we have two options:

**Option A: Two-Phase IAM (RECOMMENDED)**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TWO-PHASE IAM APPROACH                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Phase 1: iam_base                   Phase 2: eks                           │
│  ┌──────────────────┐                ┌──────────────────┐                   │
│  │ • eks_cluster    │                │ • Creates cluster │                  │
│  │ • karpenter_node │───────────────►│ • Outputs OIDC   │                   │
│  │ • bastion        │                │   provider ARN    │                  │
│  └──────────────────┘                └────────┬─────────┘                   │
│                                               │                             │
│                                               ▼                             │
│  Phase 3: iam_irsa                   Phase 4: eks addons                    │
│  ┌──────────────────┐                ┌──────────────────┐                   │
│  │ • alb_controller │                │ • ALB Controller  │                  │
│  │ • karpenter_ctrl │───────────────►│   uses IRSA role │                   │
│  │ • external_dns   │                │ • Karpenter uses  │                  │
│  └──────────────────┘                │   IRSA role       │                  │
│                                      └──────────────────┘                   │
│                                                                             │
│  BENEFIT: User has full control over ALL IAM in environment main.tf        │
│  BENEFIT: All policies are in environments/dev/policies/ (auditable)       │
│  BENEFIT: No IAM defined inside modules                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Option B: EKS Creates IRSA Internally (Less Control)**

```hcl
# NOT RECOMMENDED - User loses visibility into IAM creation

module "eks" {
  source = "../../modules/compute/eks"
  
  # EKS module creates IRSA roles internally
  # User doesn't see or control the policies
  addons = {
    alb_controller = true  # Module creates IAM internally
  }
}
```

**Recommendation:** Use **Option A** (Two-Phase IAM) because:

1. All IAM is visible in `main.tf` — nothing hidden in modules
2. All policies are JSON files in `environments/dev/policies/` — auditable and PR-reviewable
3. Environment-specific policies (dev might have different permissions than prod)
4. Easier to add new IRSA roles for future addons

---

## 4. Migration Strategy

### Approach: INCREMENTAL (Not Big Bang)

We will migrate in 5 phases, testing after each phase. This reduces risk and allows rollback at any point.

**Key Change:** The new architecture uses a **simplified module interface**. In the new structure:
- Environment `main.tf` calls only 3 main modules: `vpc`, `iam`, `eks`
- IAM is split into two calls: `iam_base` (no OIDC) and `iam_irsa` (needs OIDC)
- EKS addons are controlled via simple flags, not separate module calls
- All IAM policies are JSON files in `environments/{env}/policies/`

```
┌─────────────────────────────────────────────────────────────────┐
│                    MIGRATION PHASES                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Phase 1: Create Structure       ▓░░░░░░░░░░░░░░░░░░░  5%       │
│  Phase 2: Move Deploy            ▓▓▓░░░░░░░░░░░░░░░░░  15%      │
│  Phase 3: IAM Module + Policies  ▓▓▓▓▓▓▓▓░░░░░░░░░░░  40%      │
│  Phase 4: EKS with Internal Addons ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░  65%      │
│  Phase 5: Environment Wiring     ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  100%     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```
┌─────────────────────────────────────────────────────────────┐
│                    MIGRATION PHASES                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Phase 1: Create Structure     ▓░░░░░░░░░░░░░░░░░░░  5%     │
│  Phase 2: Move Deploy          ▓▓▓░░░░░░░░░░░░░░░░░  15%    │
│  Phase 3: Security Module      ▓▓▓▓▓▓▓▓░░░░░░░░░░░  40%    │
│  Phase 4: EKS Submodules       ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░  65%    │
│  Phase 5: Environments & State ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  100%   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Phase 1: Create New Directory Structure (Empty)

**Risk Level:** None  
**Terraform Impact:** None  
**Downtime:** None  

```bash
# Create infra structure
mkdir -p infra/modules/networking
mkdir -p infra/modules/security/iam/policies
mkdir -p infra/modules/security/security-groups
mkdir -p infra/modules/compute/eks/cluster
mkdir -p infra/modules/compute/eks/addons/alb-controller
mkdir -p infra/modules/compute/eks/addons/karpenter
mkdir -p infra/modules/compute/bastion
mkdir -p infra/modules/data/elasticache
mkdir -p infra/environments/dev
mkdir -p infra/environments/prod
mkdir -p infra/state

# Create deploy structure
mkdir -p deploy/argocd
mkdir -p deploy/helm
mkdir -p deploy/kubernetes
mkdir -p deploy/apps
mkdir -p deploy/canary
```

**Verification:**
```bash
tree infra/ deploy/ -d
```

### Phase 2: Move Deploy Manifests (Low Risk)

**Risk Level:** Low  
**Terraform Impact:** None  
**Downtime:** None  

These are pure file moves with no infrastructure changes.

```bash
# Move deployment manifests
mv argocd/* deploy/argocd/
mv helm/* deploy/helm/
mv kubernetes/* deploy/kubernetes/
mv apps/* deploy/apps/
mv canary/* deploy/canary/

# Remove empty directories
rmdir argocd helm kubernetes apps canary
```

**Files to Update:**
| File | Change |
|------|--------|
| `Makefile` | Update paths (e.g., `argocd/` → `deploy/argocd/`) |
| `scripts/deploy-argocd.sh` | Update ArgoCD manifest path |
| `README.md` | Update directory references |
| `deploy/argocd/applicationsets/*.yaml` | Update any hardcoded paths |

**Verification:**
```bash
# Validate YAML syntax
find deploy/ -name "*.yaml" -exec yamllint {} \;

# Verify ArgoCD can still parse manifests
kubectl apply --dry-run=client -f deploy/argocd/bootstrap/argocd-install.yaml
```

### Phase 3: Create IAM Module with Policy Files

**Risk Level:** Medium  
**Terraform Impact:** State migration required  
**Downtime:** Brief (during apply)  

This phase creates the new IAM module that reads policies from JSON files in the environment folder.

#### 3.1 Create Policy Directory Structure

```bash
# Create policy directories for each environment
mkdir -p infra/environments/dev/policies/trust
mkdir -p infra/environments/prod/policies/trust
```

#### 3.2 Create Trust Policy Templates

**`infra/environments/dev/policies/trust/eks-cluster.json`:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**`infra/environments/dev/policies/trust/ec2.json`:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**`infra/environments/dev/policies/trust/irsa.json.tpl`:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${oidc_provider_arn}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${oidc_provider_url}:sub": "system:serviceaccount:${namespace}:${service_account}",
          "${oidc_provider_url}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

#### 3.3 Download and Commit Permission Policies

```bash
# ALB Controller policy (download and commit, not at runtime!)
curl -o infra/environments/dev/policies/alb-controller.json \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json"

# Format it
jq . infra/environments/dev/policies/alb-controller.json > /tmp/formatted.json && \
  mv /tmp/formatted.json infra/environments/dev/policies/alb-controller.json
```

Create custom least-privilege policies (see [Section 6](#6-iam-least-privilege-design) for full JSON):
- `infra/environments/dev/policies/eks-cluster.json`
- `infra/environments/dev/policies/karpenter-controller.json`
- `infra/environments/dev/policies/karpenter-node.json`
- `infra/environments/dev/policies/bastion.json`

#### 3.4 Create the IAM Module

**`infra/modules/security/iam/main.tf`:**
```hcl
# Generic IAM Module
# Creates roles based on the `roles` map passed by the caller.
# The caller defines WHAT roles exist - this module just creates them.

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "roles" {
  type = map(object({
    description             = string
    trust_policy            = string           # JSON string or file() result
    policy_files            = list(string)     # List of policy JSON file paths
    create_instance_profile = optional(bool, false)
  }))
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}

# Create IAM roles dynamically based on input map
resource "aws_iam_role" "this" {
  for_each = var.roles

  name               = "${var.project_name}-${var.environment}-${each.key}"
  description        = each.value.description
  assume_role_policy = each.value.trust_policy

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-${each.key}"
  })
}

# Create policies from files
resource "aws_iam_policy" "this" {
  for_each = { for role_key, role in var.roles : role_key => role if length(role.policy_files) > 0 }

  name        = "${var.project_name}-${var.environment}-${each.key}-policy"
  description = "Policy for ${each.key}"
  
  # For simplicity, merge all policy files into one policy
  # In practice, you might want to handle multiple policies differently
  policy = file(each.value.policy_files[0])
}

# Attach policies to roles
resource "aws_iam_role_policy_attachment" "this" {
  for_each = aws_iam_policy.this

  role       = aws_iam_role.this[each.key].name
  policy_arn = each.value.arn
}

# Create instance profiles for EC2 roles
resource "aws_iam_instance_profile" "this" {
  for_each = { for k, v in var.roles : k => v if v.create_instance_profile }

  name = "${var.project_name}-${var.environment}-${each.key}-profile"
  role = aws_iam_role.this[each.key].name

  tags = var.tags
}

# Outputs - expose roles as a map
output "roles" {
  description = "Map of created IAM roles"
  value = {
    for k, v in aws_iam_role.this : k => {
      arn                   = v.arn
      name                  = v.name
      instance_profile_name = try(aws_iam_instance_profile.this[k].name, null)
      instance_profile_arn  = try(aws_iam_instance_profile.this[k].arn, null)
    }
  }
}
```

This module is **generic** — it doesn't know about ALB Controller or Karpenter. The caller (environment `main.tf`) defines what roles to create.

### Phase 4: Refactor EKS with Internal Addons

**Risk Level:** Medium  
**Terraform Impact:** State migration required  
**Downtime:** Brief (during apply)  

The key change: **EKS addons become internal submodules**. The user never calls them directly — they just pass `addons.alb_controller = true`.

#### 4.1 Move VPC Module

```bash
mv terraform/modules/vpc/* infra/modules/networking/vpc/
```

#### 4.2 Create EKS Module with Internal Addons

**Module Structure:**

```
infra/modules/compute/eks/
├── main.tf              # Core cluster creation
├── variables.tf         # Includes addons map, iam_role_arns, *_config
├── outputs.tf           # cluster_endpoint, oidc_provider_arn, etc.
├── addons.tf            # AWS EKS native addons (coredns, vpc-cni, etc.)
└── addons/
    ├── alb-controller/
    │   ├── main.tf      # Helm chart only
    │   └── variables.tf
    └── karpenter/
        ├── main.tf      # Helm + SQS + EventBridge
        └── variables.tf
```

**`infra/modules/compute/eks/main.tf`:**
```hcl
# EKS Module - Core cluster + internal addons
# User passes `addons = { alb_controller = true }` to enable features

variable "cluster_name" { type = string }
variable "cluster_version" { type = string }
variable "cluster_role_arn" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }

variable "addons" {
  type = object({
    coredns            = optional(bool, true)
    kube_proxy         = optional(bool, true)
    vpc_cni            = optional(bool, true)
    pod_identity_agent = optional(bool, true)
    alb_controller     = optional(bool, false)
    karpenter          = optional(bool, false)
    metrics_server     = optional(bool, true)
  })
  default = {}
}

variable "iam_role_arns" {
  type = object({
    alb_controller             = optional(string)
    karpenter_controller       = optional(string)
    karpenter_node             = optional(string)
    karpenter_instance_profile = optional(string)
  })
  default = {}
}

variable "alb_controller_config" {
  type = object({
    chart_version       = optional(string, "1.7.1")
    default_target_type = optional(string, "instance")
  })
  default = {}
}

variable "karpenter_config" {
  type = object({
    chart_version = optional(string, "1.0.1")
  })
  default = {}
}

variable "tags" { type = map(string) }

# Core EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # Cluster IAM role (passed from iam_base module)
  iam_role_arn = var.cluster_role_arn
  
  # ... other cluster configuration
  
  tags = var.tags
}

# AWS Native EKS Addons (based on flags)
resource "aws_eks_addon" "coredns" {
  count = var.addons.coredns ? 1 : 0
  
  cluster_name = module.eks.cluster_name
  addon_name   = "coredns"
}

resource "aws_eks_addon" "kube_proxy" {
  count = var.addons.kube_proxy ? 1 : 0
  
  cluster_name = module.eks.cluster_name
  addon_name   = "kube-proxy"
}

resource "aws_eks_addon" "vpc_cni" {
  count = var.addons.vpc_cni ? 1 : 0
  
  cluster_name = module.eks.cluster_name
  addon_name   = "vpc-cni"
}

resource "aws_eks_addon" "pod_identity" {
  count = var.addons.pod_identity_agent ? 1 : 0
  
  cluster_name = module.eks.cluster_name
  addon_name   = "eks-pod-identity-agent"
}

# Internal Submodule: ALB Controller
module "alb_controller" {
  source = "./addons/alb-controller"
  count  = var.addons.alb_controller ? 1 : 0

  cluster_name        = var.cluster_name
  vpc_id              = var.vpc_id
  aws_region          = data.aws_region.current.name
  iam_role_arn        = var.iam_role_arns.alb_controller
  chart_version       = var.alb_controller_config.chart_version
  default_target_type = var.alb_controller_config.default_target_type

  depends_on = [module.eks]
}

# Internal Submodule: Karpenter
module "karpenter" {
  source = "./addons/karpenter"
  count  = var.addons.karpenter ? 1 : 0

  cluster_name             = var.cluster_name
  cluster_endpoint         = module.eks.cluster_endpoint
  controller_iam_role_arn  = var.iam_role_arns.karpenter_controller
  node_iam_role_arn        = var.iam_role_arns.karpenter_node
  node_instance_profile    = var.iam_role_arns.karpenter_instance_profile
  chart_version            = var.karpenter_config.chart_version
  tags                     = var.tags

  depends_on = [module.eks]
}

data "aws_region" "current" {}

# Outputs
output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  value = module.eks.cluster_oidc_issuer_url
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}
```

**`infra/modules/compute/eks/addons/alb-controller/main.tf`:**
```hcl
# ALB Controller Addon - Helm chart only
# IAM role ARN is passed from the environment's IAM module

variable "cluster_name" { type = string }
variable "vpc_id" { type = string }
variable "aws_region" { type = string }
variable "iam_role_arn" { type = string }
variable "chart_version" { type = string }
variable "default_target_type" { type = string }

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_version
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.iam_role_arn  # From environment's iam_irsa module
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  set {
    name  = "defaultTargetType"
    value = var.default_target_type
  }
}
```

**`infra/modules/compute/eks/addons/karpenter/main.tf`:**
```hcl
# Karpenter Addon - Helm + SQS + EventBridge
# IAM role ARNs are passed from the environment's IAM modules

variable "cluster_name" { type = string }
variable "cluster_endpoint" { type = string }
variable "controller_iam_role_arn" { type = string }
variable "node_iam_role_arn" { type = string }
variable "node_instance_profile" { type = string }
variable "chart_version" { type = string }
variable "tags" { type = map(string) }

# SQS Queue for spot interruption handling
resource "aws_sqs_queue" "karpenter" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EC2InterruptionPolicy"
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter.arn
    }]
  })
}

# EventBridge rules for spot interruption and instance state changes
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.cluster_name}-karpenter-spot-interruption"
  description = "Karpenter spot instance interruption warning"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "KarpenterSpotInterruption"
  arn       = aws_sqs_queue.karpenter.arn
}

resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "${var.cluster_name}-karpenter-instance-state"
  description = "Karpenter instance state change events"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "instance_state_change" {
  rule      = aws_cloudwatch_event_rule.instance_state_change.name
  target_id = "KarpenterInstanceState"
  arn       = aws_sqs_queue.karpenter.arn
}

# Helm release
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.chart_version
  namespace        = "karpenter"
  create_namespace = true

  values = [yamlencode({
    settings = {
      clusterName       = var.cluster_name
      clusterEndpoint   = var.cluster_endpoint
      interruptionQueue = aws_sqs_queue.karpenter.name
    }
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = var.controller_iam_role_arn
      }
    }
    controller = {
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }
  })]

  depends_on = [aws_sqs_queue.karpenter]
}

output "queue_name" {
  value = aws_sqs_queue.karpenter.name
}
```

#### 4.3 Move Bastion Module

```bash
mv terraform/modules/bastion/* infra/modules/compute/bastion/
```

Update to receive IAM instance profile as input:
```hcl
# infra/modules/compute/bastion/main.tf
# Receives iam_instance_profile_name from environment's iam_base module
# NO IAM creation inside this module

variable "iam_instance_profile_name" { type = string }

resource "aws_instance" "bastion" {
  # ...
  iam_instance_profile = var.iam_instance_profile_name
}
```

#### 4.4 Move ElastiCache Module

```bash
mv terraform/modules/elasticache/* infra/modules/data/elasticache/
```

### Phase 5: Update Environments and State Migration

**Risk Level:** High  
**Terraform Impact:** Full state migration  
**Downtime:** Plan for maintenance window  

#### 5.1 New Environment Structure

```
infra/environments/dev/
├── main.tf              # Calls only: vpc, iam_base, eks, iam_irsa, bastion
├── variables.tf
├── outputs.tf
├── terraform.tfvars
└── policies/            # All IAM policies as JSON files
    ├── trust/
    │   ├── eks-cluster.json
    │   ├── ec2.json
    │   └── irsa.json.tpl
    ├── eks-cluster.json
    ├── alb-controller.json
    ├── karpenter-controller.json
    ├── karpenter-node.json
    └── bastion.json
```

#### 5.2 New Environment main.tf (Simplified)

The new wiring follows the two-phase IAM approach. **Only 3-4 main module calls** in total:

```hcl
# infra/environments/dev/main.tf
#
# KEY PRINCIPLE: "I only call vpc, iam, eks modules.
# I control WHAT gets created by passing parameters."

terraform {
  required_version = ">= 1.5"
  backend "s3" {
    bucket = "poc-eks-terraform-state"
    key    = "dev/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  cluster_name = "${var.project_name}-${var.environment}"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# MODULE 1: VPC
# ═══════════════════════════════════════════════════════════════════════════

module "vpc" {
  source = "../../modules/networking/vpc"
  
  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = "10.0.0.0/16"
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
  use_large_subnets  = var.environment == "prod"
  
  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════
# MODULE 2: IAM (Base - No OIDC dependency)
# ═══════════════════════════════════════════════════════════════════════════

module "iam_base" {
  source = "../../modules/security/iam"
  
  project_name = var.project_name
  environment  = var.environment
  
  roles = {
    eks_cluster = {
      description  = "EKS Cluster Role"
      trust_policy = file("${path.module}/policies/trust/eks-cluster.json")
      policy_files = ["${path.module}/policies/eks-cluster.json"]
    }
    karpenter_node = {
      description             = "Karpenter Node Role"
      trust_policy            = file("${path.module}/policies/trust/ec2.json")
      policy_files            = ["${path.module}/policies/karpenter-node.json"]
      create_instance_profile = true
    }
    bastion = {
      description             = "Bastion Host Role"
      trust_policy            = file("${path.module}/policies/trust/ec2.json")
      policy_files            = ["${path.module}/policies/bastion.json"]
      create_instance_profile = true
    }
  }
  
  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════
# MODULE 3: EKS (with internal addons)
# ═══════════════════════════════════════════════════════════════════════════

module "eks" {
  source = "../../modules/compute/eks"
  
  cluster_name     = local.cluster_name
  cluster_version  = "1.33"
  cluster_role_arn = module.iam_base.roles["eks_cluster"].arn
  
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids
  
  # Simple flags - internal submodules handle the rest
  addons = {
    coredns            = true
    kube_proxy         = true
    vpc_cni            = true
    pod_identity_agent = true
    alb_controller     = true
    karpenter          = var.environment == "prod"
    metrics_server     = true
  }
  
  # IAM ARNs - IRSA roles passed after creation
  iam_role_arns = {
    karpenter_node             = module.iam_base.roles["karpenter_node"].arn
    karpenter_instance_profile = module.iam_base.roles["karpenter_node"].instance_profile_name
    # IRSA roles set below via data source or second apply
  }
  
  alb_controller_config = {
    chart_version       = "1.7.1"
    default_target_type = var.environment == "prod" ? "ip" : "instance"
  }
  
  tags = local.tags
  
  depends_on = [module.iam_base]
}

# ═══════════════════════════════════════════════════════════════════════════
# MODULE 4: IAM (IRSA - Needs OIDC from EKS)
# ═══════════════════════════════════════════════════════════════════════════

module "iam_irsa" {
  source = "../../modules/security/iam"
  
  project_name      = var.project_name
  environment       = var.environment
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  
  roles = {
    alb_controller = {
      description = "ALB Controller IRSA Role"
      trust_policy = templatefile("${path.module}/policies/trust/irsa.json.tpl", {
        oidc_provider_arn = module.eks.oidc_provider_arn
        oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")
        namespace         = "kube-system"
        service_account   = "aws-load-balancer-controller"
      })
      policy_files = ["${path.module}/policies/alb-controller.json"]
    }
    karpenter_controller = {
      description = "Karpenter Controller IRSA Role"
      trust_policy = templatefile("${path.module}/policies/trust/irsa.json.tpl", {
        oidc_provider_arn = module.eks.oidc_provider_arn
        oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")
        namespace         = "karpenter"
        service_account   = "karpenter"
      })
      policy_files = ["${path.module}/policies/karpenter-controller.json"]
    }
  }
  
  tags = local.tags
  
  depends_on = [module.eks]
}

# ═══════════════════════════════════════════════════════════════════════════
# MODULE 5: BASTION (Optional)
# ═══════════════════════════════════════════════════════════════════════════

module "bastion" {
  source = "../../modules/compute/bastion"
  
  name                      = "${local.cluster_name}-bastion"
  vpc_id                    = module.vpc.vpc_id
  subnet_id                 = module.vpc.public_subnet_ids[0]
  iam_instance_profile_name = module.iam_base.roles["bastion"].instance_profile_name
  cluster_name              = local.cluster_name
  cluster_endpoint          = module.eks.cluster_endpoint
  
  tags = local.tags
  
  depends_on = [module.eks]
}

# ═══════════════════════════════════════════════════════════════════════════
# OUTPUTS
# ═══════════════════════════════════════════════════════════════════════════

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_name" {
  value = local.cluster_name
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "alb_controller_role_arn" {
  value = module.iam_irsa.roles["alb_controller"].arn
}
```

**Note on IRSA Role Wiring:** The EKS module needs to be updated to accept IRSA role ARNs _after_ creation. Two approaches:

1. **Two-pass apply**: First apply creates EKS + OIDC. Second apply passes IRSA ARNs to helm charts.
2. **Dynamic reference**: Use `coalesce()` and module dependencies to wire them in single apply.

The recommended approach is to structure the EKS module to install addons as a separate step that can reference IRSA roles.

#### 5.3 Execute State Migration

See [Section 5](#5-terraform-state-migration) for detailed commands.

---

## 5. Terraform State Migration

### 5.1 Pre-Migration Checklist

- [ ] Backup current state file
- [ ] Document all resource addresses
- [ ] Test migration in dev environment first
- [ ] Schedule maintenance window for prod
- [ ] Notify team of planned changes

### 5.2 Backup Strategy

```bash
# Create backup directory
mkdir -p state-backups/$(date +%Y%m%d)

# Backup dev state
cd infra/environments/dev
terraform state pull > ../../../state-backups/$(date +%Y%m%d)/dev-state.json

# Backup prod state
cd ../prod
terraform state pull > ../../../state-backups/$(date +%Y%m%d)/prod-state.json

# Verify backups
ls -la state-backups/$(date +%Y%m%d)/
```

### 5.3 State Migration Commands

**IMPORTANT:** Run these AFTER moving module files but BEFORE running `terraform plan`.

```bash
# Navigate to environment
cd infra/environments/dev

# ─────────────────────────────────────────────────────────────
# VPC Module (simple path change)
# ─────────────────────────────────────────────────────────────
# No state move needed if source path is updated correctly

# ─────────────────────────────────────────────────────────────
# ALB Controller → Security Module (IAM)
# ─────────────────────────────────────────────────────────────
terraform state mv \
  'module.alb_controller.aws_iam_policy.alb_controller' \
  'module.iam.aws_iam_policy.alb_controller'

terraform state mv \
  'module.alb_controller.module.alb_controller_irsa' \
  'module.iam.module.alb_controller_irsa'

# ─────────────────────────────────────────────────────────────
# ALB Controller → Security Module (Security Group)
# ─────────────────────────────────────────────────────────────
terraform state mv \
  'module.alb_controller.aws_security_group.alb' \
  'module.security_groups.aws_security_group.alb'

# ─────────────────────────────────────────────────────────────
# Karpenter → Security Module (IAM)
# ─────────────────────────────────────────────────────────────
terraform state mv \
  'module.karpenter.module.karpenter_irsa' \
  'module.iam.module.karpenter_controller_irsa'

terraform state mv \
  'module.karpenter.module.karpenter_node_role' \
  'module.iam.aws_iam_role.karpenter_node'

terraform state mv \
  'module.karpenter.aws_iam_instance_profile.karpenter' \
  'module.iam.aws_iam_instance_profile.karpenter'

# ─────────────────────────────────────────────────────────────
# Bastion → Security Module (IAM)
# ─────────────────────────────────────────────────────────────
terraform state mv \
  'module.bastion.aws_iam_role.bastion' \
  'module.iam.aws_iam_role.bastion'

terraform state mv \
  'module.bastion.aws_iam_role_policy_attachment.ssm' \
  'module.iam.aws_iam_role_policy_attachment.bastion_ssm'

terraform state mv \
  'module.bastion.aws_iam_role_policy.eks_access' \
  'module.iam.aws_iam_policy.bastion_eks'

terraform state mv \
  'module.bastion.aws_iam_instance_profile.bastion' \
  'module.iam.aws_iam_instance_profile.bastion'

# ─────────────────────────────────────────────────────────────
# Bastion → Security Module (Security Group)
# ─────────────────────────────────────────────────────────────
terraform state mv \
  'module.bastion.aws_security_group.bastion' \
  'module.security_groups.aws_security_group.bastion'

# ─────────────────────────────────────────────────────────────
# ALB Controller Module Path Change
# ─────────────────────────────────────────────────────────────
terraform state mv \
  'module.alb_controller.helm_release.alb_controller' \
  'module.alb_controller.helm_release.alb_controller'
# Note: This may need adjustment based on actual module structure

# ─────────────────────────────────────────────────────────────
# Karpenter Module Path Change
# ─────────────────────────────────────────────────────────────
terraform state mv \
  'module.karpenter.aws_sqs_queue.karpenter' \
  'module.karpenter.aws_sqs_queue.karpenter'

terraform state mv \
  'module.karpenter.helm_release.karpenter' \
  'module.karpenter.helm_release.karpenter'
```

### 5.4 Post-Migration Verification

```bash
# Run plan to verify no unexpected changes
terraform plan -out=migration-plan.tfplan

# Expected output:
# - No resources to create or destroy
# - Possible "update in-place" for tags or minor changes

# If plan shows destroy/create, STOP and investigate
# Compare state addresses with new module structure

# Only apply if plan looks correct
terraform apply migration-plan.tfplan
```

### 5.5 State Migration Script

Create `scripts/state-migration.sh`:

```bash
#!/bin/bash
set -euo pipefail

ENV="${1:-dev}"
DRY_RUN="${2:-true}"

echo "=== State Migration for $ENV environment ==="
echo "Dry run: $DRY_RUN"

cd "infra/environments/$ENV"

# Backup first
echo "Creating backup..."
terraform state pull > "state-backup-$(date +%Y%m%d-%H%M%S).json"

# Define migrations
declare -A MIGRATIONS=(
  # ALB Controller IAM
  ["module.alb_controller.aws_iam_policy.alb_controller"]="module.iam.aws_iam_policy.alb_controller"
  ["module.alb_controller.module.alb_controller_irsa"]="module.iam.module.alb_controller_irsa"
  
  # ALB Security Group
  ["module.alb_controller.aws_security_group.alb"]="module.security_groups.aws_security_group.alb"
  
  # Karpenter IAM
  ["module.karpenter.module.karpenter_irsa"]="module.iam.module.karpenter_controller_irsa"
  ["module.karpenter.aws_iam_instance_profile.karpenter"]="module.iam.aws_iam_instance_profile.karpenter"
  
  # Bastion IAM
  ["module.bastion.aws_iam_role.bastion"]="module.iam.aws_iam_role.bastion"
  ["module.bastion.aws_iam_instance_profile.bastion"]="module.iam.aws_iam_instance_profile.bastion"
  
  # Bastion Security Group
  ["module.bastion.aws_security_group.bastion"]="module.security_groups.aws_security_group.bastion"
)

for src in "${!MIGRATIONS[@]}"; do
  dst="${MIGRATIONS[$src]}"
  echo "Moving: $src → $dst"
  
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] Would execute: terraform state mv '$src' '$dst'"
  else
    terraform state mv "$src" "$dst" || echo "  [WARN] Failed to move $src"
  fi
done

echo ""
echo "=== Migration complete ==="
echo "Run 'terraform plan' to verify"
```

---

## 6. IAM Least Privilege Design

### 6.1 Key Principle: Policies Live in Environment Folder

**Policies are NOT hardcoded in modules.** They live as JSON files in each environment folder:

```
environments/dev/policies/         # Dev environment policies
├── trust/
│   ├── eks-cluster.json          # EKS cluster trust policy
│   ├── ec2.json                  # EC2 trust policy (bastion, karpenter node)
│   └── irsa.json.tpl             # IRSA trust policy template
├── eks-cluster.json              # EKS cluster permissions
├── alb-controller.json           # ALB controller permissions (downloaded from official)
├── karpenter-controller.json     # Karpenter controller permissions (custom)
├── karpenter-node.json           # Karpenter node permissions (custom, least-privilege)
└── bastion.json                  # Bastion permissions

environments/prod/policies/        # Prod environment policies (can differ!)
└── ...                           # Prod might have stricter or different policies
```

**Why this matters:**
1. **Auditable**: All policies are version-controlled, not downloaded at runtime
2. **PR-reviewable**: Security team can review policy changes
3. **Environment-specific**: Prod can have different permissions than dev
4. **Visible**: User sees exactly what IAM is created by looking at `main.tf` + `policies/`

### 6.2 IAM Roles Overview

| Role Name | Defined In | Trust Policy | Permission Policy |
|-----------|------------|--------------|-------------------|
| `{project}-{env}-eks_cluster` | `iam_base` | `policies/trust/eks-cluster.json` | `policies/eks-cluster.json` |
| `{project}-{env}-karpenter_node` | `iam_base` | `policies/trust/ec2.json` | `policies/karpenter-node.json` |
| `{project}-{env}-bastion` | `iam_base` | `policies/trust/ec2.json` | `policies/bastion.json` |
| `{project}-{env}-alb_controller` | `iam_irsa` | `policies/trust/irsa.json.tpl` | `policies/alb-controller.json` |
| `{project}-{env}-karpenter_controller` | `iam_irsa` | `policies/trust/irsa.json.tpl` | `policies/karpenter-controller.json` |

### 6.3 Trust Policy Files

**`policies/trust/eks-cluster.json`:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**`policies/trust/ec2.json`:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**`policies/trust/irsa.json.tpl`** (template for IRSA roles):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${oidc_provider_arn}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${oidc_provider_url}:sub": "system:serviceaccount:${namespace}:${service_account}",
          "${oidc_provider_url}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

### 6.4 ALB Controller Policy

**Source:** Downloaded from official repo and committed (NOT fetched at runtime!)

```bash
# One-time download and commit
curl -o environments/dev/policies/alb-controller.json \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json"

# Copy to prod (or customize if needed)
cp environments/dev/policies/alb-controller.json environments/prod/policies/
```

### 6.5 Karpenter Controller Policy (Custom, Least-Privilege)

**`policies/karpenter-controller.json`:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowScopedEC2InstanceActions",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:CreateFleet"
      ],
      "Resource": [
        "arn:aws:ec2:*:*:launch-template/*",
        "arn:aws:ec2:*:*:security-group/*",
        "arn:aws:ec2:*:*:subnet/*",
        "arn:aws:ec2:*::image/*",
        "arn:aws:ec2:*:*:instance/*",
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:ec2:*:*:network-interface/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/karpenter.sh/discovery": "${cluster_name}"
        }
      }
    },
    {
      "Sid": "AllowScopedEC2InstanceActionsWithTags",
      "Effect": "Allow",
      "Action": [
        "ec2:TerminateInstances",
        "ec2:DeleteLaunchTemplate"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "ec2:ResourceTag/karpenter.sh/discovery": "${cluster_name}"
        }
      }
    },
    {
      "Sid": "AllowScopedResourceCreationTagging",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": [
        "arn:aws:ec2:*:*:instance/*",
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:ec2:*:*:network-interface/*",
        "arn:aws:ec2:*:*:launch-template/*"
      ],
      "Condition": {
        "StringEquals": {
          "ec2:CreateAction": ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
        }
      }
    },
    {
      "Sid": "AllowPassingRoleToEC2",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/*-karpenter_node",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    },
    {
      "Sid": "AllowScopedInstanceProfileActions",
      "Effect": "Allow",
      "Action": [
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:DeleteInstanceProfile"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/karpenter.sh/discovery": "${cluster_name}"
        }
      }
    },
    {
      "Sid": "AllowGetInstanceProfile",
      "Effect": "Allow",
      "Action": "iam:GetInstanceProfile",
      "Resource": "*"
    },
    {
      "Sid": "AllowReadActions",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeSubnets"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowSSMReadActions",
      "Effect": "Allow",
      "Action": "ssm:GetParameter",
      "Resource": "arn:aws:ssm:*:*:parameter/aws/service/*"
    },
    {
      "Sid": "AllowPricingReadActions",
      "Effect": "Allow",
      "Action": "pricing:GetProducts",
      "Resource": "*"
    },
    {
      "Sid": "AllowSQSActions",
      "Effect": "Allow",
      "Action": [
        "sqs:DeleteMessage",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage"
      ],
      "Resource": "arn:aws:sqs:*:*:*-karpenter"
    },
    {
      "Sid": "AllowEKSDescribe",
      "Effect": "Allow",
      "Action": "eks:DescribeCluster",
      "Resource": "arn:aws:eks:*:*:cluster/${cluster_name}"
    }
  ]
}
```

### 6.6 Karpenter Node Policy (Custom, Least-Privilege)

**`policies/karpenter-node.json`:**

This replaces the overly-permissive AWS managed policies:
- ~~AmazonEKSWorkerNodePolicy~~ (too broad: `ec2:Describe*` on all resources)
- ~~AmazonEKS_CNI_Policy~~ (scoped down to what's actually needed)
- ~~AmazonEC2ContainerRegistryReadOnly~~ (kept as-is, minimal permissions)
- ~~AmazonSSMManagedInstanceCore~~ (REMOVED - not needed for worker nodes)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EKSWorkerNode",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeVolumes",
        "ec2:DescribeVolumesModifications",
        "ec2:DescribeVpcs",
        "eks:DescribeCluster"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EKSCNI",
      "Effect": "Allow",
      "Action": [
        "ec2:AssignPrivateIpAddresses",
        "ec2:AttachNetworkInterface",
        "ec2:CreateNetworkInterface",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DetachNetworkInterface",
        "ec2:ModifyNetworkInterfaceAttribute",
        "ec2:UnassignPrivateIpAddresses"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRRead",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetAuthorizationToken",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "*"
    }
  ]
}
```

### 6.7 Bastion Policy

**`policies/bastion.json`:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EKSDescribe",
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "eks:ListClusters"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SSMSessionManager",
      "Effect": "Allow",
      "Action": [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ],
      "Resource": "*"
    }
  ]
}
```

### 6.8 Adding New IRSA Roles

When you need a new IRSA role (e.g., external-dns), you:

1. Create the policy file: `environments/dev/policies/external-dns.json`
2. Add the role to `iam_irsa` in `main.tf`:

```hcl
module "iam_irsa" {
  # ...existing config...
  
  roles = {
    # ...existing roles...
    
    external_dns = {
      description = "External DNS IRSA Role"
      trust_policy = templatefile("${path.module}/policies/trust/irsa.json.tpl", {
        oidc_provider_arn = module.eks.oidc_provider_arn
        oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")
        namespace         = "external-dns"
        service_account   = "external-dns"
      })
      policy_files = ["${path.module}/policies/external-dns.json"]
    }
  }
}
```

That's it. The IAM module creates the role. No module changes needed.

---

## 7. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| **Terraform state corruption** | Medium | High | Backup state before each migration step. Test in dev first. Use `terraform state mv` carefully. |
| **Service disruption during migration** | Medium | High | Perform migration during maintenance window. Use incremental approach. Have rollback plan ready. |
| **Circular dependency resurfaces** | Low | Medium | Security module creates all SGs first. Document dependency order in environment main.tf. |
| **IAM policy too restrictive** | Medium | Medium | Test custom policies thoroughly in dev. Keep AWS managed policy ARNs documented for quick rollback. |
| **Broken references after file moves** | Medium | Low | Update all paths in Makefile, scripts, README. Use grep to find all references before moving. |
| **ArgoCD sync failures** | Low | Medium | Validate all YAML files after moving. Test ArgoCD sync in dev cluster first. |
| **Team confusion during transition** | Medium | Low | Document everything. Communicate timeline. Keep old structure until migration complete. |
| **Downloaded ALB policy changes upstream** | Low | Medium | Commit policy to repo. Pin to specific version (v2.7.1). Review changes when upgrading. |

---

## 8. Rollback Plan

### 8.1 Phase-Level Rollback

| Phase | Rollback Steps |
|-------|---------------|
| **Phase 1** (Structure) | Delete empty directories: `rm -rf infra/ deploy/` |
| **Phase 2** (Deploy move) | Move files back: `mv deploy/* .` and restore from git |
| **Phase 3** (Security module) | Restore state backup, revert module files from git |
| **Phase 4** (EKS refactor) | Restore state backup, revert module files from git |
| **Phase 5** (Environments) | Restore state backup, revert environment files from git |

### 8.2 State Rollback Procedure

```bash
# If something goes wrong during state migration:

# 1. Stop immediately - don't run terraform apply
# 2. Restore state from backup
cd infra/environments/dev
terraform state push state-backup-YYYYMMDD-HHMMSS.json

# 3. Verify state restored
terraform state list

# 4. Revert file changes
git checkout -- .

# 5. Verify plan shows no changes
terraform plan
```

### 8.3 IAM Policy Rollback

If custom policies are too restrictive:

```hcl
# Quick rollback: Use AWS managed policies temporarily
# In security/iam/main.tf, change:

# FROM:
resource "aws_iam_role_policy_attachment" "karpenter_node" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = aws_iam_policy.karpenter_node.arn
}

# TO (rollback):
resource "aws_iam_role_policy_attachment" "karpenter_node_eks" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
```

### 8.4 Full Rollback (Emergency)

If everything fails and we need to restore to pre-migration state:

```bash
# 1. Checkout previous commit
git log --oneline -10  # Find pre-migration commit
git checkout <pre-migration-commit>

# 2. Restore state from S3 backup
aws s3 cp s3://your-state-bucket/backups/dev-state-YYYYMMDD.json .
terraform state push dev-state-YYYYMMDD.json

# 3. Verify
terraform plan  # Should show no changes

# 4. If stable, create new branch from known-good state
git checkout -b rollback-stable
```

---

## 9. Success Criteria

### 9.1 Structure Verification

- [ ] `infra/` contains all Terraform code
- [ ] `deploy/` contains all Kubernetes/Helm manifests
- [ ] No Terraform files outside `infra/`
- [ ] No K8s manifests outside `deploy/`
- [ ] `docs/` structure unchanged

### 9.2 Security Module Verification

- [ ] All IAM roles defined in `infra/modules/security/iam/`
- [ ] All IAM policies as JSON files in `infra/modules/security/iam/policies/`
- [ ] All security groups defined in `infra/modules/security/security-groups/`
- [ ] No IAM resources in other modules
- [ ] No security groups in other modules (except EKS internal SGs)

### 9.3 EKS Submodules Verification

- [ ] ALB Controller is submodule at `infra/modules/compute/eks/addons/alb-controller/`
- [ ] Karpenter is submodule at `infra/modules/compute/eks/addons/karpenter/`
- [ ] Addons receive IAM role ARNs as input variables
- [ ] Addons do not create IAM resources

### 9.4 Dependency Resolution Verification

- [ ] `alb_security_group_id = null` hack removed
- [ ] SG rule ALB → NodePort works correctly
- [ ] `terraform plan` shows no circular dependency errors
- [ ] Module creation order documented in environment main.tf

### 9.5 IAM Least Privilege Verification

- [ ] ALB Controller policy committed to repo (not downloaded at runtime)
- [ ] Karpenter node role uses custom policy (not AWS managed)
- [ ] All policies are reviewable in PR
- [ ] IAM Access Analyzer shows no unused permissions (run after 90 days)

### 9.6 Functional Verification

- [ ] `terraform plan` shows no unexpected changes
- [ ] `terraform apply` succeeds without errors
- [ ] EKS cluster accessible via kubectl
- [ ] ALB Controller creates ALBs from Ingress
- [ ] Karpenter provisions nodes on demand
- [ ] Bastion accessible via Session Manager
- [ ] ArgoCD syncs applications successfully

### 9.7 Documentation Verification

- [ ] README.md updated with new structure
- [ ] Makefile paths updated
- [ ] Scripts paths updated
- [ ] DEPLOYMENT-GUIDE.md updated

---

## 10. Timeline Estimate

| Phase | Duration | Dependencies | Milestone |
|-------|----------|--------------|-----------|
| **Phase 1:** Create structure | 1 hour | None | Empty directories created |
| **Phase 2:** Move deploy manifests | 2 hours | Phase 1 | All K8s manifests under `deploy/` |
| **Phase 3:** Security module | 1 day | Phase 2 | IAM/SGs centralized, policies as JSON |
| **Phase 4:** EKS submodules | 1 day | Phase 3 | Addons refactored, no circular deps |
| **Phase 5:** Environments & state | 1 day | Phase 4 | Dev migrated and tested |
| **Prod migration** | 0.5 day | Phase 5 dev complete | Prod migrated and tested |
| **Documentation** | 0.5 day | All phases | All docs updated |

**Total Estimated Time:** 5 days

### Recommended Schedule

| Day | Activities |
|-----|------------|
| **Day 1** | Phase 1 + Phase 2 (structure + deploy manifests) |
| **Day 2** | Phase 3 (security module, IAM policies, dev testing) |
| **Day 3** | Phase 4 (EKS submodules, dev testing) |
| **Day 4** | Phase 5 (environments, state migration dev, full dev testing) |
| **Day 5** | Prod migration (maintenance window) + documentation |

### Prerequisites Before Starting

1. [ ] Team aligned on approach
2. [ ] Maintenance window scheduled for prod (Day 5)
3. [ ] State backups verified
4. [ ] Dev environment accessible for testing
5. [ ] Rollback procedure reviewed by team

---

## Appendix A: Quick Reference Commands

### State Backup
```bash
terraform state pull > backup-$(date +%Y%m%d-%H%M%S).json
```

### State Migration
```bash
terraform state mv 'old.address' 'new.address'
```

### Validate Structure
```bash
tree infra/ deploy/ -d
```

### Validate YAML
```bash
find deploy/ -name "*.yaml" -exec yamllint {} \;
```

### Validate Terraform
```bash
cd infra/environments/dev && terraform validate
```

---

## Appendix B: File Movement Summary

| Source | Destination |
|--------|-------------|
| `terraform/` | `infra/` |
| `terraform/modules/vpc/` | `infra/modules/networking/vpc/` |
| `terraform/modules/eks/` | `infra/modules/compute/eks/cluster/` |
| `terraform/modules/alb-controller/` (IAM) | `infra/modules/security/iam/` |
| `terraform/modules/alb-controller/` (SG) | `infra/modules/security/security-groups/` |
| `terraform/modules/alb-controller/` (Helm) | `infra/modules/compute/eks/addons/alb-controller/` |
| `terraform/modules/karpenter/` (IAM) | `infra/modules/security/iam/` |
| `terraform/modules/karpenter/` (Helm+SQS) | `infra/modules/compute/eks/addons/karpenter/` |
| `terraform/modules/bastion/` (IAM) | `infra/modules/security/iam/` |
| `terraform/modules/bastion/` (SG) | `infra/modules/security/security-groups/` |
| `terraform/modules/bastion/` (EC2) | `infra/modules/compute/bastion/` |
| `terraform/modules/elasticache/` (SG) | `infra/modules/security/security-groups/` |
| `terraform/modules/elasticache/` (Redis) | `infra/modules/data/elasticache/` |
| `argocd/` | `deploy/argocd/` |
| `helm/` | `deploy/helm/` |
| `kubernetes/` | `deploy/kubernetes/` |
| `apps/` | `deploy/apps/` |
| `canary/` | `deploy/canary/` |

---

**Document Version:** 2.0  
**Last Updated:** 2026-03-29  
**Next Review:** After Phase 5 completion

---

## Changelog

### v2.1 (2026-03-29)
- Fixed IRSA role wiring example in section 3.5.4 to reference `module.iam_irsa` directly
- Removed obsolete "UPDATE EKS ADDONS WITH IRSA ROLES" section (Terraform resolves dependencies automatically)
- Added explanation of how Terraform resolves the apparent circular dependency

### v2.0 (2026-03-29)
- Added Section 3.4: Module Interface Design Principles
- Added Section 3.5: Module Interface Examples with complete code
- Redesigned IAM module to accept roles as a map (caller defines what to create)
- Redesigned EKS module with internal addons (user passes `addons.alb_controller = true`)
- Moved IAM policies from module folder to environment folder (`environments/dev/policies/`)
- Added two-phase IAM approach to handle OIDC chicken-egg problem
- Updated migration strategy phases to reflect new design
- Updated Section 6 to document policies-in-environment-folder approach

### v1.0 (2026-03-29)
- Initial proposal
