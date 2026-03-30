# ADR-005: Project Structure Reorganization

## Status
Accepted

## Context
The POC EKS AWS project initially had a flat structure mixing infrastructure code (Terraform) with deployment manifests (Kubernetes/Helm) and scattered security concerns (IAM policies) across multiple modules. This organization created several problems:

**Security and Auditability Issues:**
- IAM policies scattered across 3 modules (alb-controller, karpenter, bastion)
- ALB controller policy downloaded from GitHub at `terraform apply` time — not version controlled or PR-reviewable
- AWS managed policies used for Karpenter (over-permissioned, not least-privilege)
- No central location for security audit of IAM permissions

**Circular Dependency Problem:**
```
EKS Module ←→ ALB Controller Module
│              │
├─ Needs: ALB SG ID      
│  (for node SG rule)    
│              │
└─ Creates: OIDC Provider ─→ Needs: EKS OIDC ARN (for IRSA)

CURRENT HACK: alb_security_group_id = null
RESULT: Security group rules don't work correctly
```

**Structural Issues:**
- 5 top-level folders for deployment concerns (argocd/, apps/, canary/, helm/, kubernetes/)
- No clear separation between infrastructure provisioning and workload deployment
- EKS addons (ALB controller, Karpenter) mixed IAM, security groups, and Helm charts in single modules

## Decision
Reorganize the project into a **two-root structure** with dedicated security module and dependency-breaking architecture:

### New Structure
```
poc-eks-aws/
├── infra/           # ALL Terraform infrastructure
│   ├── modules/
│   │   ├── networking/vpc/
│   │   ├── security/
│   │   │   ├── iam/
│   │   │   │   ├── main.tf
│   │   │   │   └── policies/        # JSON policy files
│   │   │   │       ├── alb-controller.json
│   │   │   │       ├── karpenter-controller.json
│   │   │   │       ├── karpenter-node.json
│   │   │   │       └── bastion-eks-access.json
│   │   │   └── security-groups/
│   │   ├── compute/
│   │   │   ├── eks/
│   │   │   │   ├── cluster/         # Core EKS
│   │   │   │   └── addons/          # ALB controller, Karpenter
│   │   │   └── bastion/
│   │   └── data/elasticache/
│   └── environments/
│       ├── dev/
│       └── prod/
│
└── deploy/          # ALL Kubernetes/GitOps manifests
    ├── argocd/
    ├── helm/
    ├── kubernetes/
    ├── apps/
    └── canary/
```

### Key Architecture Decisions

#### 1. Two-Phase IAM Approach
Solves the OIDC chicken-egg problem:

```
Phase 1: iam_base        Phase 2: eks
┌──────────────┐        ┌──────────────┐
│ • eks_cluster│───────►│ • Creates    │
│ • karpenter  │        │   cluster    │
│   _node      │        │ • Outputs    │
│ • bastion    │        │   OIDC ARN   │
└──────────────┘        └──────┬───────┘
                               │
Phase 3: iam_irsa       Phase 4: eks addons
┌──────────────┐        ┌──────────────┐
│ • alb_ctrl   │───────►│ • ALB uses   │
│ • karpenter  │        │   IRSA role  │
│   _controller│        │ • Karpenter  │
└──────────────┘        │   uses IRSA  │
                        └──────────────┘
```

**Benefit:** User has full control over ALL IAM in environment `main.tf`, nothing hidden inside modules.

#### 2. Security Groups Created First
Break circular dependencies by creating security groups BEFORE EKS:

```
1. security/security-groups → Creates all SGs
2. compute/eks/cluster      → Receives SG IDs as parameters
3. compute/eks/addons       → Use existing SGs, no creation
```

#### 3. IAM Policies as JSON Files
All IAM policies stored in `environments/{env}/policies/` directory:
- Version controlled
- PR reviewable
- Auditable
- Environment-specific customization
- No runtime downloads

#### 4. Caller Controls Creation
Modules don't create IAM or security groups internally:
- Caller decides what to create via parameters
- Modules receive ARNs/IDs from caller
- Clear ownership and visibility

#### 5. Modules Focused on Single Concern
- `security/iam` → Only IAM roles and policies
- `security/security-groups` → Only security groups
- `compute/eks/cluster` → Only EKS cluster
- `compute/eks/addons/alb-controller` → Only Helm chart
- `compute/eks/addons/karpenter` → Only Helm chart + SQS + EventBridge

## Consequences

### Positive
- **Security auditability**: All IAM policies in JSON files, version controlled, PR reviewable
- **No circular dependencies**: Two-phase IAM and SG-first approach eliminates hacks
- **Clean separation**: Infrastructure (`infra/`) vs deployment (`deploy/`) concerns
- **Maintainability**: EKS addons as submodules, clear module boundaries
- **Least privilege**: Custom IAM policies replace AWS managed policies
- **Developer experience**: Clear where to add new components
- **Module reusability**: Modules don't have hidden side effects

### Negative
- **Migration complexity**: Requires Terraform state moves (handled via `terraform state mv`)
- **Two-phase IAM calls**: Environment `main.tf` must call IAM module twice (base + IRSA)
- **More explicit wiring**: Caller must wire security group IDs between modules (but this is actually a benefit — explicit > implicit)
- **Learning curve**: Team must understand dependency ordering (SG → EKS → IRSA → addons)

### Migration Completed
The project was successfully migrated on 2026-03-29 (commit 8cffeb2) with:
- All modules reorganized under `infra/modules/`
- Deployment manifests consolidated under `deploy/`
- IAM policies extracted to JSON files in `infra/environments/dev/policies/`
- Security groups centralized in `security/security-groups` module
- Two-phase IAM implemented in environment `main.tf`
- Terraform state successfully migrated without recreation

### Security Improvements Achieved
- ✅ All IAM policies auditable in source control
- ✅ No runtime policy downloads
- ✅ Custom least-privilege policies for Karpenter
- ✅ Security groups created with proper ingress/egress rules
- ✅ No `null` hacks or workarounds

## Alternatives Considered

### Keep Flat Structure with Fixes
**Rejected**: Would address circular dependencies but wouldn't solve:
- Scattered IAM concerns
- Poor separation of infra vs deploy
- Runtime policy downloads
- Module boundary violations

### Single-Phase IAM with `depends_on`
**Rejected**: Attempted to create all IAM roles in single pass using `depends_on`:
- Doesn't work — IRSA roles need OIDC provider ARN that only exists after EKS creation
- `depends_on` creates resource ordering, not output availability
- Two-phase is cleaner and makes dependencies explicit

### Modules Create IAM Internally
**Rejected**: Letting EKS addon modules create their own IAM roles:
- Hides IAM creation from caller
- Can't audit what IAM is created without reading module internals
- Makes environment-specific IAM policies harder
- Violates principle of explicit control

### Keep `terraform/` Directory Name
**Rejected**: Renaming to `infra/` provides:
- Clearer intent (not all infra is Terraform, e.g., future Pulumi/CDK)
- Matches industry patterns (Terraform Modules Registry uses `modules/`)
- Distinguishes infrastructure from deployment concerns

## References
- [Original Proposal](../archive/IMPLEMENTED-PROJECT-STRUCTURE-REFACTOR.md)
- [ADR-001: IP Mode for Production](./001-ip-mode-for-production.md)
- [Terraform State Management Best Practices](https://developer.hashicorp.com/terraform/language/state)
- [AWS IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
