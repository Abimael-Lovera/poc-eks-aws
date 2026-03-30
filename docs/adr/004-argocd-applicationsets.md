# ADR-004: ArgoCD ApplicationSets for Multi-Environment Deployment

## Status
Accepted

## Context
Kong API Gateway must be deployed to multiple environments (dev, staging, production) with:
- Consistent configuration structure across environments
- Environment-specific values (replicas, resources, feature flags)
- Different sync policies per environment (auto-sync for dev, manual for prod)
- GitOps workflow with single source of truth
- Ability to add new environments without duplicating Application manifests

ArgoCD provides two approaches for multi-environment:
- **Multiple Application CRDs**: One Application per environment
- **ApplicationSet**: Single definition that generates Applications via generators

## Decision
Use **ArgoCD ApplicationSets with list generator** for Kong multi-environment deployment.

### ApplicationSet Configuration
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: kong-gateway
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - env: dev
            cluster: https://kubernetes.default.svc
            namespace: kong-dev
            valueFile: dev.yaml
            autoSync: true
          - env: staging
            cluster: https://kubernetes.default.svc
            namespace: kong-staging
            valueFile: staging.yaml
            autoSync: false
          - env: prod
            cluster: https://prod-cluster-endpoint
            namespace: kong-prod
            valueFile: prod.yaml
            autoSync: false

  template:
    metadata:
      name: 'kong-{{env}}'
      labels:
        app: kong
        env: '{{env}}'
    spec:
      project: kong-project
      source:
        repoURL: https://charts.konghq.com
        chart: kong
        targetRevision: 2.38.0
        helm:
          valueFiles:
            - $values/helm/values/kong/base.yaml
            - $values/helm/values/kong/{{valueFile}}
      destination:
        server: '{{cluster}}'
        namespace: '{{namespace}}'
      syncPolicy:
        automated:
          prune: '{{autoSync}}'
          selfHeal: '{{autoSync}}'
```

### Values Structure
```
helm/values/kong/
├── base.yaml      # Shared configuration
├── dev.yaml       # Dev overrides (2 replicas, debug logging)
├── staging.yaml   # Staging overrides (2 replicas, info logging)
└── prod.yaml      # Prod overrides (3+ replicas, warn logging, IP mode)
```

## Consequences

### Positive
- **Single source of truth**: One ApplicationSet generates all environment Applications
- **DRY configuration**: No duplicate Application manifests per environment
- **Consistent structure**: All environments follow same pattern, reducing drift
- **Easy to add environments**: Add element to list generator, no new files needed
- **Environment-specific policies**: Dev auto-syncs, staging/prod require manual approval
- **GitOps native**: All changes tracked in Git, auditable promotion workflow
- **Sync waves support**: Order deployment of dependencies (namespace → Redis → Kong → plugins)

### Negative
- **List generator limitations**: Hardcoded environment list in ApplicationSet
- **Less flexibility than cluster generator**: Cannot auto-discover environments
- **Debugging complexity**: Template variables can make troubleshooting harder
- **ApplicationSet controller dependency**: Additional component that can fail
- **Learning curve**: Team must understand ApplicationSet templating syntax

### Sync Policy by Environment
| Environment | Auto-Sync | Self-Heal | Approval |
|-------------|-----------|-----------|----------|
| dev | Yes | Yes | None |
| staging | No | No | PR review |
| prod | No | No | PR + Change Request |

### Promotion Workflow
```
Git Push → Dev (auto) → PR → Staging (manual) → CR → Prod (manual)
           ~immediate    ~1 hour              ~1 day
```

## Alternatives Considered

### Multiple Application CRDs
**Rejected**: Creating separate `kong-dev.yaml`, `kong-staging.yaml`, `kong-prod.yaml`:
- Duplication of 90% identical configuration
- Risk of configuration drift between environments
- Adding new environment requires new file + copy-paste
- Harder to enforce consistent patterns

### Kustomize Overlays Only (No ArgoCD)
**Rejected**: Using Kustomize without ArgoCD:
- Requires manual `kubectl apply` or CI-based deployment
- No drift detection or self-healing
- No UI for deployment visibility
- Loses GitOps benefits (declarative, auditable, reversible)

### Cluster Generator
**Rejected**: ArgoCD cluster generator auto-discovers clusters:
- Overkill for known, fixed set of environments
- Requires cluster secrets with specific labels
- Less explicit than list generator
- Better suited for dynamic multi-tenant scenarios

### Matrix Generator
**Rejected**: Combining multiple generators (e.g., clusters × apps):
- Adds complexity without benefit for single-app use case
- Useful when deploying multiple apps to multiple clusters
- Kong is single application, list generator is sufficient

### Git Generator
**Rejected**: Generating Applications from directory structure:
- Requires specific directory layout (`envs/dev/`, `envs/staging/`)
- Less flexible than explicit list
- Harder to customize per-environment settings
- Better suited for microservices monorepo patterns
