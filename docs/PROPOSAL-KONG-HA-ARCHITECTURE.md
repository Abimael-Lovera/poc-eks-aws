# Kong HA Architecture Proposal

## DB-less Mode con Helm, ArgoCD, Canary Deploy, Multi-AZ, Redis

**Fecha:** 2026-03-26  
**Status:** Propuesta  
**Autor:** POC EKS AWS Team

---

## 📋 Índice

1. [Resumen Ejecutivo](#resumen-ejecutivo)
2. [Arquitectura General](#arquitectura-general)
3. [Propuesta A: IP Mode (Producción)](#propuesta-a-ip-mode-producción)
4. [Propuesta B: Instance Mode (Dev/Staging)](#propuesta-b-instance-mode-devstaging)
5. [GitOps Workflow con ArgoCD](#gitops-workflow-con-argocd)
6. [Canary Deployment con Flagger](#canary-deployment-con-flagger)
7. [API Contract Deployment](#api-contract-deployment)
8. [Redis HA para Rate Limiting](#redis-ha-para-rate-limiting)
9. [Comparación de Trade-offs](#comparación-de-trade-offs)
10. [Decisión y Recomendaciones](#decisión-y-recomendaciones)

---

## Resumen Ejecutivo

Esta propuesta presenta **dos arquitecturas** para Kong API Gateway en Amazon EKS con alta disponibilidad:

| Propuesta | Ambiente | ALB Mode | Redis | Canary |
|-----------|----------|----------|-------|--------|
| **A** | Production | IP Mode | ElastiCache Multi-AZ | Flagger |
| **B** | Dev/Staging | Instance Mode | Redis Sentinel | Rolling Update |

**Componentes compartidos:**
- 🔄 **ArgoCD** para GitOps
- 📦 **Helm** para packaging
- 🌍 **Multi-AZ** (3 AZs)
- 🔴 **Redis** para rate-limiting distribuido
- 🐦 **Canary deployments** (Flagger)

---

## Arquitectura General

### Stack Tecnológico

```
┌─────────────────────────────────────────────────────────────────────┐
│                         GITOPS LAYER                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐             │
│  │    Git      │───▶│   ArgoCD    │───▶│   Flagger   │             │
│  │ (Source of  │    │  (Sync &    │    │  (Canary    │             │
│  │   Truth)    │    │  Deploy)    │    │  Analysis)  │             │
│  └─────────────┘    └─────────────┘    └─────────────┘             │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       KUBERNETES (EKS)                               │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Kong API Gateway                          │   │
│  │         (DB-less Mode - Config via CRDs)                     │   │
│  │  ┌─────────┐    ┌─────────┐    ┌─────────┐                  │   │
│  │  │ Kong-0  │    │ Kong-1  │    │ Kong-2  │                  │   │
│  │  │  AZ-a   │    │  AZ-b   │    │  AZ-c   │                  │   │
│  │  └─────────┘    └─────────┘    └─────────┘                  │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              ▼                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │              Backend Services / Microservices                │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       DATA LAYER (AWS)                               │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │              Redis (Rate Limiting State)                     │   │
│  │         ElastiCache Multi-AZ / Redis Sentinel                │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Propuesta A: IP Mode (Producción)

### Arquitectura de Red

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AWS REGION (us-east-1)                          │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                              VPC (10.0.0.0/16)                          │ │
│  │                                                                         │ │
│  │   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐       │ │
│  │   │   PUBLIC AZ-a   │  │   PUBLIC AZ-b   │  │   PUBLIC AZ-c   │       │ │
│  │   │   10.0.1.0/24   │  │   10.0.2.0/24   │  │   10.0.3.0/24   │       │ │
│  │   │                 │  │                 │  │                 │       │ │
│  │   │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │       │ │
│  │   │  │    ALB    │  │  │  │    ALB    │  │  │  │    ALB    │  │       │ │
│  │   │  │   (ENI)   │  │  │  │   (ENI)   │  │  │  │   (ENI)   │  │       │ │
│  │   │  └─────┬─────┘  │  │  └─────┬─────┘  │  │  └─────┬─────┘  │       │ │
│  │   └────────┼────────┘  └────────┼────────┘  └────────┼────────┘       │ │
│  │            │                    │                    │                 │ │
│  │            │         IP MODE (Direct to Pod)         │                 │ │
│  │            │                    │                    │                 │ │
│  │   ┌────────┼────────┐  ┌────────┼────────┐  ┌────────┼────────┐       │ │
│  │   │  PRIVATE AZ-a   │  │  PRIVATE AZ-b   │  │  PRIVATE AZ-c   │       │ │
│  │   │  10.0.10.0/23   │  │  10.0.12.0/23   │  │  10.0.14.0/23   │       │ │
│  │   │                 │  │                 │  │                 │       │ │
│  │   │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │       │ │
│  │   │  │  Kong-0   │  │  │  │  Kong-1   │  │  │  │  Kong-2   │  │       │ │
│  │   │  │10.0.10.50 │◀─┼──┼──│10.0.12.51 │◀─┼──┼──│10.0.14.52 │  │       │ │
│  │   │  │  :8000    │  │  │  │  :8000    │  │  │  │  :8000    │  │       │ │
│  │   │  └───────────┘  │  │  └───────────┘  │  │  └───────────┘  │       │ │
│  │   │        │        │  │        │        │  │        │        │       │ │
│  │   │        ▼        │  │        ▼        │  │        ▼        │       │ │
│  │   │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │       │ │
│  │   │  │ Backend   │  │  │  │ Backend   │  │  │  │ Backend   │  │       │ │
│  │   │  │  Pods     │  │  │  │  Pods     │  │  │  │  Pods     │  │       │ │
│  │   │  └───────────┘  │  │  └───────────┘  │  │  └───────────┘  │       │ │
│  │   └─────────────────┘  └─────────────────┘  └─────────────────┘       │ │
│  │                                                                         │ │
│  │   ┌─────────────────────────────────────────────────────────────────┐  │ │
│  │   │                    ElastiCache Redis Multi-AZ                    │  │ │
│  │   │  ┌─────────┐              ┌─────────┐              ┌─────────┐  │  │ │
│  │   │  │ Primary │◀── Replica ──│ Replica │              │ Replica │  │  │ │
│  │   │  │  AZ-a   │              │  AZ-b   │              │  AZ-c   │  │  │ │
│  │   │  └─────────┘              └─────────┘              └─────────┘  │  │ │
│  │   └─────────────────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Flujo de Request (IP Mode)

```
┌──────────┐    ┌──────────┐    ┌──────────────┐    ┌──────────────┐
│  Client  │───▶│   ALB    │───▶│   Kong Pod   │───▶│   Backend    │
│          │    │          │    │ (Direct IP)  │    │   Service    │
└──────────┘    └──────────┘    └──────────────┘    └──────────────┘
                     │                  │
                     │                  │
              ┌──────▼──────┐    ┌──────▼──────┐
              │ Health Check│    │    Redis    │
              │ (Pod Level) │    │ Rate Limit  │
              └─────────────┘    └─────────────┘

Latency: ~1-2ms (ALB → Pod)
Hops: 1 (directo al Pod)
Health: Pod-level (true readiness)
```

### Configuración IP Mode

```yaml
# Service con anotaciones para IP mode
apiVersion: v1
kind: Service
metadata:
  name: kong-proxy
  namespace: kong
  annotations:
    # IP Mode - ALB apunta directo a Pod IPs
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
spec:
  type: LoadBalancer
  ports:
    - name: proxy
      port: 80
      targetPort: 8000
    - name: proxy-ssl
      port: 443
      targetPort: 8443
```

```yaml
# Pod Readiness Gate (namespace label)
apiVersion: v1
kind: Namespace
metadata:
  name: kong
  labels:
    elbv2.k8s.aws/pod-readiness-gate-inject: enabled
```

### Requisitos IP Mode

| Requisito | Estado | Notas |
|-----------|--------|-------|
| VPC CNI | ✅ Default en EKS | Ya configurado |
| Subnets /23 o mayor | ⚠️ Verificar | Cada pod = 1 VPC IP |
| Pod Readiness Gates | ⚠️ Configurar | Label en namespace |
| Security Groups | ⚠️ Configurar | ALB SG → Pod SG directo |

---

## Propuesta B: Instance Mode (Dev/Staging)

### Arquitectura de Red

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AWS REGION (us-east-1)                          │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                              VPC (10.0.0.0/16)                          │ │
│  │                                                                         │ │
│  │   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐       │ │
│  │   │   PUBLIC AZ-a   │  │   PUBLIC AZ-b   │  │   PUBLIC AZ-c   │       │ │
│  │   │                 │  │                 │  │                 │       │ │
│  │   │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │       │ │
│  │   │  │   NLB     │  │  │  │   NLB     │  │  │  │   NLB     │  │       │ │
│  │   │  │  (ENI)    │  │  │  │  (ENI)    │  │  │  │  (ENI)    │  │       │ │
│  │   │  └─────┬─────┘  │  │  └─────┬─────┘  │  │  └─────┬─────┘  │       │ │
│  │   └────────┼────────┘  └────────┼────────┘  └────────┼────────┘       │ │
│  │            │                    │                    │                 │ │
│  │            │       INSTANCE MODE (Via NodePort)      │                 │ │
│  │            ▼                    ▼                    ▼                 │ │
│  │   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐       │ │
│  │   │  PRIVATE AZ-a   │  │  PRIVATE AZ-b   │  │  PRIVATE AZ-c   │       │ │
│  │   │                 │  │                 │  │                 │       │ │
│  │   │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │       │ │
│  │   │  │   Node    │  │  │  │   Node    │  │  │  │   Node    │  │       │ │
│  │   │  │ :30080    │  │  │  │ :30080    │  │  │  │ :30080    │  │       │ │
│  │   │  │     │     │  │  │  │     │     │  │  │  │     │     │  │       │ │
│  │   │  │ ┌───▼───┐ │  │  │  │ ┌───▼───┐ │  │  │  │ ┌───▼───┐ │  │       │ │
│  │   │  │ │ Kong  │ │  │  │  │ │ Kong  │ │  │  │  │ │ Kong  │ │  │       │ │
│  │   │  │ │  Pod  │ │  │  │  │ │  Pod  │ │  │  │  │ │  Pod  │ │  │       │ │
│  │   │  │ └───────┘ │  │  │  │ └───────┘ │  │  │  │ └───────┘ │  │       │ │
│  │   │  └───────────┘  │  │  └───────────┘  │  │  └───────────┘  │       │ │
│  │   └─────────────────┘  └─────────────────┘  └─────────────────┘       │ │
│  │                                                                         │ │
│  │   ┌─────────────────────────────────────────────────────────────────┐  │ │
│  │   │                    Redis Sentinel (Kubernetes)                   │  │ │
│  │   │  ┌─────────┐       ┌─────────┐       ┌─────────┐                │  │ │
│  │   │  │ Redis-0 │       │ Redis-1 │       │ Redis-2 │                │  │ │
│  │   │  │ Master  │◀─────▶│ Replica │◀─────▶│ Replica │                │  │ │
│  │   │  │  AZ-a   │       │  AZ-b   │       │  AZ-c   │                │  │ │
│  │   │  └────┬────┘       └────┬────┘       └────┬────┘                │  │ │
│  │   │       │                 │                 │                      │  │ │
│  │   │  ┌────▼────┐       ┌────▼────┐       ┌────▼────┐                │  │ │
│  │   │  │Sentinel │       │Sentinel │       │Sentinel │                │  │ │
│  │   │  │   -0    │◀─────▶│   -1    │◀─────▶│   -2    │                │  │ │
│  │   │  └─────────┘       └─────────┘       └─────────┘                │  │ │
│  │   │                    Quorum = 2                                    │  │ │
│  │   └─────────────────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Flujo de Request (Instance Mode)

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  Client  │───▶│   NLB    │───▶│   Node   │───▶│   Kong   │───▶│ Backend  │
│          │    │          │    │ NodePort │    │   Pod    │    │ Service  │
└──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘
                     │                │               │
              ┌──────▼──────┐         │        ┌──────▼──────┐
              │ Health Check│    iptables      │    Redis    │
              │ (Node Level)│     NAT          │ Rate Limit  │
              └─────────────┘                  └─────────────┘

Latency: ~3-5ms (NLB → Node → iptables → Pod)
Hops: 2 (Node + iptables NAT)
Health: Node-level (no pod awareness)
```

### Configuración Instance Mode

```yaml
# Service con NodePort para Instance mode
apiVersion: v1
kind: Service
metadata:
  name: kong-proxy
  namespace: kong
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "instance"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
spec:
  type: LoadBalancer
  ports:
    - name: proxy
      port: 80
      targetPort: 8000
      nodePort: 30080
    - name: proxy-ssl
      port: 443
      targetPort: 8443
      nodePort: 30443
```

---

## GitOps Workflow con ArgoCD

### Estructura de Repositorio

```
poc-eks-aws/
├── argocd/
│   ├── bootstrap/
│   │   └── argocd-install.yaml         # ArgoCD installation
│   │
│   ├── projects/
│   │   └── kong-project.yaml           # ArgoCD Project (RBAC)
│   │
│   └── applicationsets/
│       ├── kong-gateway.yaml           # Kong multi-env
│       ├── kong-plugins.yaml           # KongPlugin CRDs
│       └── redis.yaml                  # Redis (Sentinel o ElastiCache config)
│
├── helm/
│   └── values/
│       └── kong/
│           ├── base.yaml               # Valores compartidos
│           ├── dev.yaml                # Dev overrides
│           ├── staging.yaml            # Staging overrides
│           └── prod.yaml               # Prod overrides
│
├── apps/
│   └── kong/
│       ├── base/
│       │   ├── kustomization.yaml
│       │   ├── namespace.yaml
│       │   └── kong-plugins.yaml       # Rate limiting, auth, etc.
│       │
│       └── overlays/
│           ├── dev/
│           │   ├── kustomization.yaml
│           │   └── patches/
│           ├── staging/
│           └── prod/
│
└── canary/
    └── kong-canary.yaml                # Flagger Canary config
```

### ArgoCD ApplicationSet

```yaml
# argocd/applicationsets/kong-gateway.yaml
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
            autoSync: false          # Manual approval
          - env: prod
            cluster: https://prod-cluster-endpoint
            namespace: kong-prod
            valueFile: prod.yaml
            autoSync: false          # Manual approval + change request

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

      sources:
        - repoURL: https://github.com/your-org/poc-eks-aws
          targetRevision: main
          ref: values

      destination:
        server: '{{cluster}}'
        namespace: '{{namespace}}'

      syncPolicy:
        automated:
          prune: '{{autoSync}}'
          selfHeal: '{{autoSync}}'
        syncOptions:
          - CreateNamespace=true
          - PruneLast=true
        retry:
          limit: 3
          backoff:
            duration: 5s
            maxDuration: 3m
            factor: 2
```

### Workflow de Promoción

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           GITOPS PROMOTION FLOW                              │
│                                                                              │
│   ┌─────────┐         ┌─────────┐         ┌─────────┐         ┌─────────┐  │
│   │   Git   │         │   Dev   │         │ Staging │         │  Prod   │  │
│   │  Push   │         │         │         │         │         │         │  │
│   └────┬────┘         └────┬────┘         └────┬────┘         └────┬────┘  │
│        │                   │                   │                   │        │
│        │    Auto-sync      │                   │                   │        │
│        ├──────────────────▶│                   │                   │        │
│        │                   │                   │                   │        │
│        │                   │   PR + Approval   │                   │        │
│        │                   ├──────────────────▶│                   │        │
│        │                   │                   │                   │        │
│        │                   │                   │   Change Request  │        │
│        │                   │                   │   + Approval      │        │
│        │                   │                   ├──────────────────▶│        │
│        │                   │                   │                   │        │
│   ─────┴───────────────────┴───────────────────┴───────────────────┴─────   │
│                                                                              │
│   Tiempo:    Inmediato        ~1 hora           ~1 día                      │
│   Gate:      Ninguno          Manual            Manual + CR                 │
│   Rollback:  Git revert       Git revert        Git revert                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Sync Waves (Orden de Deployment)

```yaml
# Wave 0: Namespace y CRDs
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"

# Wave 1: Redis / Secrets
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"

# Wave 2: Kong Gateway
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "2"

# Wave 3: Kong Plugins
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "3"

# Wave 4: Ingress / Routes
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "4"
```

---

## Canary Deployment con Flagger

### Arquitectura Canary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CANARY DEPLOYMENT FLOW                               │
│                                                                              │
│                              ┌─────────────┐                                │
│                              │  Flagger    │                                │
│                              │ Controller  │                                │
│                              └──────┬──────┘                                │
│                                     │                                        │
│               ┌─────────────────────┼─────────────────────┐                 │
│               │                     │                     │                 │
│               ▼                     ▼                     ▼                 │
│        ┌─────────────┐       ┌─────────────┐       ┌─────────────┐         │
│        │  Metrics    │       │   Traffic   │       │  Rollback   │         │
│        │  Analysis   │       │   Shifting  │       │  Decision   │         │
│        │ (Prometheus)│       │   (Kong)    │       │             │         │
│        └─────────────┘       └─────────────┘       └─────────────┘         │
│                                     │                                        │
│               ┌─────────────────────┼─────────────────────┐                 │
│               │                     │                     │                 │
│               ▼                     ▼                     ▼                 │
│   ┌───────────────────┐    ┌───────────────────┐    ┌───────────────┐      │
│   │  Primary (Stable) │    │  Canary (New)     │    │   Analysis    │      │
│   │                   │    │                   │    │   Metrics     │      │
│   │   90% Traffic     │    │   10% Traffic     │    │               │      │
│   │                   │    │                   │    │ - Success %   │      │
│   │  ┌─────┐ ┌─────┐  │    │  ┌─────┐         │    │ - Latency p99 │      │
│   │  │Pod-0│ │Pod-1│  │    │  │Pod-C│         │    │ - Error rate  │      │
│   │  └─────┘ └─────┘  │    │  └─────┘         │    │               │      │
│   └───────────────────┘    └───────────────────┘    └───────────────┘      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘


                         CANARY PROGRESSION TIMELINE
    
    ┌────────┬────────┬────────┬────────┬────────┬────────┬────────┐
    │  0%    │  10%   │  20%   │  40%   │  60%   │  80%   │ 100%   │
    │        │        │        │        │        │        │        │
    │ Start  │  +1m   │  +2m   │  +3m   │  +4m   │  +5m   │ +6m    │
    └────────┴────────┴────────┴────────┴────────┴────────┴────────┘
                  │
                  ▼
           ┌─────────────┐
           │  Analysis   │ ◀── Si falla: Rollback automático
           │  (cada 1m)  │
           └─────────────┘
```

### Flagger Canary Configuration

```yaml
# canary/kong-canary.yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: kong-gateway
  namespace: kong
spec:
  # Deployment target
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: kong-gateway

  # Traffic routing (Kong native)
  provider: kong

  # Ingress reference
  ingressRef:
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    name: kong-proxy

  # Autoscaler reference (opcional)
  autoscalerRef:
    apiVersion: autoscaling/v2
    kind: HorizontalPodAutoscaler
    name: kong-gateway

  # Canary analysis
  analysis:
    # Análisis cada 1 minuto
    interval: 1m
    
    # Número de checks fallidos antes de rollback
    threshold: 5
    
    # Máximo tráfico al canary
    maxWeight: 50
    
    # Incremento de tráfico por paso
    stepWeight: 10
    
    # Métricas de análisis
    metrics:
      # Request success rate (debe ser > 99%)
      - name: request-success-rate
        thresholdRange:
          min: 99
        interval: 1m
      
      # Latency p99 (debe ser < 500ms)
      - name: request-duration
        thresholdRange:
          max: 500
        interval: 1m

    # Webhooks para notificaciones
    webhooks:
      - name: notify-slack
        type: post-analysis
        url: http://slack-notifier/
        timeout: 5s
        metadata:
          channel: "#deployments"

  # Progressive delivery settings
  progressDeadlineSeconds: 600  # 10 min max para completar

  # Service configuration
  service:
    port: 80
    targetPort: 8000

    # Traffic policy
    trafficPolicy:
      connectionPool:
        tcp:
          maxConnections: 100
        http:
          h2UpgradePolicy: UPGRADE
```

### Prometheus Metrics para Canary

```yaml
# Métricas que Flagger analiza
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kong-metrics
  namespace: kong
spec:
  selector:
    matchLabels:
      app: kong
  endpoints:
    - port: metrics
      interval: 15s
      path: /metrics
```

```promql
# Request Success Rate
sum(rate(kong_http_requests_total{code!~"5.."}[1m]))
/
sum(rate(kong_http_requests_total[1m]))

# Request Duration p99
histogram_quantile(0.99, 
  sum(rate(kong_request_latency_ms_bucket[1m])) by (le)
)
```

---

## API Contract Deployment

### Contract-First Development

El enfoque **contract-first** establece que la especificación OpenAPI es la fuente de verdad, no el código.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      CONTRACT-FIRST WORKFLOW                                 │
│                                                                              │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐ │
│   │  OpenAPI    │───▶│   Lint &    │───▶│   Code      │───▶│   Deploy    │ │
│   │   Spec      │    │  Validate   │    │   Generate  │    │   to K8s    │ │
│   │  (Git)      │    │ (Spectral)  │    │  (Types)    │    │  (ArgoCD)   │ │
│   └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘ │
│         │                   │                   │                   │       │
│         ▼                   ▼                   ▼                   ▼       │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                         CI/CD PIPELINE                               │  │
│   │  1. Lint spec (spectral)                                            │  │
│   │  2. Detect breaking changes (openapi-diff)                          │  │
│   │  3. Generate types/clients                                          │  │
│   │  4. Generate Kong config (deck)                                     │  │
│   │  5. Commit generated artifacts                                      │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Estructura de Directorio

```
poc-eks-aws/
├── specs/
│   └── openapi/
│       ├── api-v1.yaml              # OpenAPI spec v1
│       ├── api-v2.yaml              # OpenAPI spec v2
│       └── .spectral.yaml           # Linting rules
│
├── generated/
│   ├── types/                       # Generated TypeScript/Go types
│   ├── clients/                     # Generated API clients
│   └── kong/                        # Generated Kong declarative config
│
└── apps/
    └── kong/
        └── base/
            └── routes-generated.yaml  # Kong routes from OpenAPI
```

### Validación en CI/CD

```yaml
# .github/workflows/api-contract.yaml
name: API Contract Validation

on:
  pull_request:
    paths:
      - 'specs/openapi/**'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      # Lint OpenAPI spec
      - name: Lint OpenAPI
        uses: stoplightio/spectral-action@v0.8.10
        with:
          file_glob: 'specs/openapi/*.yaml'
          spectral_ruleset: 'specs/openapi/.spectral.yaml'
      
      # Detect breaking changes
      - name: Check Breaking Changes
        run: |
          npx openapi-diff \
            specs/openapi/api-v1.yaml \
            specs/openapi/api-v1.yaml \
            --fail-on-incompatible
      
      # Generate Kong config
      - name: Generate Kong Routes
        run: |
          deck file openapi2kong \
            --spec specs/openapi/api-v1.yaml \
            --output-file generated/kong/routes.yaml
```

### Kong + OpenAPI Integration

Kong puede consumir especificaciones OpenAPI directamente para generar rutas y habilitar validación de requests.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    OPENAPI → KONG WORKFLOW                                   │
│                                                                              │
│   ┌─────────────┐         ┌─────────────┐         ┌─────────────┐          │
│   │  OpenAPI    │  deck   │   Kong      │  ArgoCD │   Kong      │          │
│   │   Spec      │────────▶│  Declarative│────────▶│  Gateway    │          │
│   │             │ convert │   Config    │  sync   │  (Runtime)  │          │
│   └─────────────┘         └─────────────┘         └─────────────┘          │
│                                                                              │
│   Herramientas:                                                             │
│   • deck file openapi2kong - Convierte OpenAPI a Kong config                │
│   • deck gateway sync - Sincroniza config con Kong                          │
│   • Kong Request Validator Plugin - Valida requests contra spec             │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Generación de Rutas con Deck

```bash
# Convertir OpenAPI a Kong declarative config
deck file openapi2kong \
  --spec specs/openapi/api-v1.yaml \
  --output-file generated/kong/routes.yaml \
  --select-tag api-v1
```

Ejemplo de output generado:

```yaml
# generated/kong/routes.yaml (auto-generated from OpenAPI)
_format_version: "3.0"
services:
  - name: users-service
    url: http://users-service.default.svc.cluster.local:8080
    tags:
      - api-v1
      - openapi-generated
    routes:
      - name: get-users
        paths:
          - /api/v1/users
        methods:
          - GET
        tags:
          - api-v1
      - name: create-user
        paths:
          - /api/v1/users
        methods:
          - POST
        tags:
          - api-v1
      - name: get-user-by-id
        paths:
          - /api/v1/users/(?<id>[^/]+)
        methods:
          - GET
        tags:
          - api-v1
```

### Request Validation Plugin

```yaml
# apps/kong/base/request-validator-plugin.yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: request-validator
  namespace: kong
plugin: request-validator
config:
  body_schema: |
    {
      "type": "object",
      "required": ["name", "email"],
      "properties": {
        "name": {"type": "string", "minLength": 1},
        "email": {"type": "string", "format": "email"}
      }
    }
  parameter_schema:
    - name: id
      in: path
      required: true
      schema:
        type: string
        pattern: "^[0-9a-f]{24}$"
  verbose_response: true
```

### Integración con ArgoCD Sync Waves

```yaml
# Los contratos se sincronizan ANTES que los servicios
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"  # Kong routes (from OpenAPI)

# Los servicios se despliegan DESPUÉS
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "2"  # Kong Gateway

# Los plugins se aplican AL FINAL
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "3"  # Request Validator Plugin
```

### Workflow Completo: Contract → Canary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              CONTRACT-AWARE CANARY DEPLOYMENT                                │
│                                                                              │
│   1. PR con cambio en OpenAPI spec                                          │
│      │                                                                       │
│      ▼                                                                       │
│   2. CI: Lint + Breaking Change Detection                                   │
│      │                                                                       │
│      ├── ❌ Breaking change detectado → PR bloqueado                        │
│      │                                                                       │
│      ▼                                                                       │
│   3. CI: Generar Kong config (deck openapi2kong)                            │
│      │                                                                       │
│      ▼                                                                       │
│   4. Merge → ArgoCD detecta cambio                                          │
│      │                                                                       │
│      ▼                                                                       │
│   5. Sync Wave 1: Deploy Kong routes (from OpenAPI)                         │
│      │                                                                       │
│      ▼                                                                       │
│   6. Sync Wave 2: Deploy service (Canary)                                   │
│      │                                                                       │
│      ▼                                                                       │
│   7. Flagger: Progressive traffic shift                                      │
│      │                                                                       │
│      ├── ❌ Canary metrics fail → Rollback                                  │
│      │                                                                       │
│      ▼                                                                       │
│   8. ✅ 100% traffic to new version                                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Versionado de Contratos

| Estrategia | Path | Header | Query Param |
|------------|------|--------|-------------|
| **Ejemplo** | `/api/v1/users` | `Accept: application/vnd.api.v1+json` | `/users?version=1` |
| **Kong Route** | `paths: [/api/v1]` | `headers.Accept: ~*v1` | N/A |
| **Recomendado** | ✅ Sí | Para APIs internas | No |

```yaml
# Kong routes para múltiples versiones
routes:
  - name: users-v1
    paths:
      - /api/v1/users
    service: users-service-v1
  - name: users-v2
    paths:
      - /api/v2/users
    service: users-service-v2
```

---

## Redis HA para Rate Limiting

### Opción A: ElastiCache Multi-AZ (Producción)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       ELASTICACHE MULTI-AZ TOPOLOGY                          │
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                      ElastiCache Cluster                             │   │
│   │                                                                      │   │
│   │    ┌─────────────┐      ┌─────────────┐      ┌─────────────┐       │   │
│   │    │   Primary   │      │  Replica 1  │      │  Replica 2  │       │   │
│   │    │   (Write)   │─────▶│   (Read)    │─────▶│   (Read)    │       │   │
│   │    │   AZ-a      │      │   AZ-b      │      │   AZ-c      │       │   │
│   │    └──────┬──────┘      └─────────────┘      └─────────────┘       │   │
│   │           │                                                         │   │
│   │           │ Automatic Failover                                      │   │
│   │           ▼                                                         │   │
│   │    ┌─────────────────────────────────────────────────────────┐     │   │
│   │    │           Primary Endpoint (DNS Auto-update)            │     │   │
│   │    │      master.my-redis.abc123.use1.cache.amazonaws.com    │     │   │
│   │    └─────────────────────────────────────────────────────────┘     │   │
│   │                                                                      │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│   Kong Pods ──────────────────────────────────────────────▶ Primary Endpoint│
│                                                                              │
│   SLA: 99.99%                                                               │
│   Failover: ~30 segundos (automático)                                       │
│   Backup: Diario automático                                                 │
│   Encryption: In-transit + At-rest                                          │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Opción B: Redis Sentinel (Dev/Staging)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       REDIS SENTINEL TOPOLOGY                                │
│                                                                              │
│   ┌───────────────────────────────────────────────────────────────────┐     │
│   │                      Sentinel Cluster                              │     │
│   │   ┌─────────┐         ┌─────────┐         ┌─────────┐            │     │
│   │   │Sentinel │◀───────▶│Sentinel │◀───────▶│Sentinel │            │     │
│   │   │   -0    │         │   -1    │         │   -2    │            │     │
│   │   │  AZ-a   │         │  AZ-b   │         │  AZ-c   │            │     │
│   │   └────┬────┘         └────┬────┘         └────┬────┘            │     │
│   │        │                   │                   │                  │     │
│   │        │         Quorum = 2 for failover       │                  │     │
│   │        │                   │                   │                  │     │
│   └────────┼───────────────────┼───────────────────┼──────────────────┘     │
│            │                   │                   │                        │
│            ▼                   ▼                   ▼                        │
│   ┌─────────────────────────────────────────────────────────────────┐      │
│   │                       Redis Cluster                              │      │
│   │   ┌─────────┐         ┌─────────┐         ┌─────────┐           │      │
│   │   │ Redis   │────────▶│ Redis   │────────▶│ Redis   │           │      │
│   │   │ Master  │         │ Replica │         │ Replica │           │      │
│   │   │  AZ-a   │         │  AZ-b   │         │  AZ-c   │           │      │
│   │   └─────────┘         └─────────┘         └─────────┘           │      │
│   │                                                                  │      │
│   └─────────────────────────────────────────────────────────────────┘      │
│                                                                              │
│   Kong Pods ──▶ Sentinel Discovery ──▶ Current Master                       │
│                                                                              │
│   Failover: ~15-30 segundos (sentinel triggered)                            │
│   Quorum: 2 de 3 sentinels deben acordar para failover                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Kong Rate Limiting Plugin

```yaml
# apps/kong/base/rate-limiting-plugin.yaml
apiVersion: configuration.konghq.com/v1
kind: KongClusterPlugin
metadata:
  name: global-rate-limit
  annotations:
    kubernetes.io/ingress.class: kong
  labels:
    global: "true"
plugin: rate-limiting
config:
  # Límites
  minute: 1000                    # 1000 requests por minuto
  hour: 50000                     # 50000 requests por hora
  
  # Política: Redis para contadores distribuidos
  policy: redis
  
  # ElastiCache (Prod)
  redis_host: master.my-redis.abc123.use1.cache.amazonaws.com
  redis_port: 6379
  redis_ssl: true
  redis_ssl_verify: true
  redis_timeout: 1000             # 1 segundo timeout
  
  # Comportamiento
  fault_tolerant: true            # Si Redis falla, permite requests
  hide_client_headers: false      # Muestra X-RateLimit-* headers
  
  # Identificador
  limit_by: consumer              # o "ip", "header", "path"
```

```yaml
# Para Redis Sentinel (Dev/Staging)
config:
  policy: redis
  redis_host: null                # No usar host directo
  redis_sentinel_master: mymaster
  redis_sentinel_addresses:
    - redis-sentinel-0.redis-sentinel:26379
    - redis-sentinel-1.redis-sentinel:26379
    - redis-sentinel-2.redis-sentinel:26379
```

---

## Comparación de Trade-offs

### IP Mode vs Instance Mode

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        COMPARACIÓN: IP vs INSTANCE MODE                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   LATENCIA                                                                   │
│   ┌────────────────────────────────────────────────────────┐                │
│   │ IP Mode      ████████░░░░░░░░░░░░ 1-2ms               │                │
│   │ Instance     ████████████████░░░░ 3-5ms               │                │
│   └────────────────────────────────────────────────────────┘                │
│                                                                              │
│   COMPLEJIDAD DE SETUP                                                       │
│   ┌────────────────────────────────────────────────────────┐                │
│   │ IP Mode      ████████████████░░░░ Alta                │                │
│   │ Instance     ████████░░░░░░░░░░░░ Baja                │                │
│   └────────────────────────────────────────────────────────┘                │
│                                                                              │
│   CONSUMO DE VPC IPs                                                        │
│   ┌────────────────────────────────────────────────────────┐                │
│   │ IP Mode      ████████████████████ Alto (1 IP/pod)     │                │
│   │ Instance     ████░░░░░░░░░░░░░░░░ Bajo (1 IP/node)    │                │
│   └────────────────────────────────────────────────────────┘                │
│                                                                              │
│   HEALTH CHECK PRECISION                                                     │
│   ┌────────────────────────────────────────────────────────┐                │
│   │ IP Mode      ████████████████████ Pod-level (preciso) │                │
│   │ Instance     ████████████░░░░░░░░ Node-level          │                │
│   └────────────────────────────────────────────────────────┘                │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Tabla Comparativa Completa

| Característica | Propuesta A (IP Mode) | Propuesta B (Instance Mode) |
|---------------|----------------------|----------------------------|
| **Ambiente** | Production | Dev/Staging |
| **Latencia** | ~1-2ms | ~3-5ms |
| **Health Checks** | Pod-level (preciso) | Node-level |
| **VPC IPs** | Alto consumo | Bajo consumo |
| **CNI Required** | VPC CNI only | Cualquier CNI |
| **Setup** | Complejo | Simple |
| **Costo Infra** | ~$150/mes | ~$80/mes |
| | | |
| **Redis** | ElastiCache Multi-AZ | Redis Sentinel (K8s) |
| **Redis SLA** | 99.99% | Self-managed |
| **Redis Costo** | ~$50/mes | ~$20/mes (compute) |
| **Redis Ops** | Zero (AWS managed) | Alto (self-managed) |
| | | |
| **Canary** | Flagger (full) | Rolling Update |
| **GitOps** | ArgoCD auto-sync | ArgoCD manual |
| **AZs** | 3 | 2-3 |
| **Replicas** | 3+ | 2+ |

### Costo Estimado Mensual

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          ESTIMACIÓN DE COSTOS (USD/mes)                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   PROPUESTA A (Production - IP Mode)                                        │
│   ┌────────────────────────────────────────────────────────────────────┐   │
│   │ EKS Cluster                                            $73         │   │
│   │ EC2 Nodes (3x t3.medium)                              $90         │   │
│   │ ALB                                                    $25         │   │
│   │ ElastiCache Redis (cache.t4g.small Multi-AZ)          $50         │   │
│   │ NAT Gateway                                            $45         │   │
│   │ Data Transfer                                          $20         │   │
│   ├────────────────────────────────────────────────────────────────────┤   │
│   │ TOTAL                                                 ~$303/mes    │   │
│   └────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│   PROPUESTA B (Dev/Staging - Instance Mode)                                 │
│   ┌────────────────────────────────────────────────────────────────────┐   │
│   │ EKS Cluster                                            $73         │   │
│   │ EC2 Nodes (2x t3.medium)                              $60         │   │
│   │ NLB                                                    $20         │   │
│   │ Redis Sentinel (runs on existing nodes)                $0         │   │
│   │ NAT Gateway (single)                                   $32         │   │
│   │ Data Transfer                                          $10         │   │
│   ├────────────────────────────────────────────────────────────────────┤   │
│   │ TOTAL                                                 ~$195/mes    │   │
│   └────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Decisión y Recomendaciones

### Recomendación Final

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           RECOMENDACIÓN                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                                                                      │  │
│   │   DESARROLLO / STAGING          PRODUCCIÓN                          │  │
│   │   ═══════════════════          ══════════                           │  │
│   │                                                                      │  │
│   │   ✅ Propuesta B                ✅ Propuesta A                       │  │
│   │      Instance Mode                 IP Mode                          │  │
│   │      Redis Sentinel                ElastiCache                      │  │
│   │      NLB                           ALB                              │  │
│   │      2 AZs                         3 AZs                            │  │
│   │      Rolling Updates               Flagger Canary                   │  │
│   │                                                                      │  │
│   │   Costo: ~$195/mes              Costo: ~$303/mes                    │  │
│   │                                                                      │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│   JUSTIFICACIÓN:                                                            │
│   ─────────────                                                             │
│   • Dev/Staging no requiere latencia mínima ni SLA de Redis                │
│   • Production necesita pod-level health checks y failover automático      │
│   • Canary es crítico en prod para detectar issues antes de rollout        │
│   • ElastiCache elimina operational overhead en producción                  │
│   • Instance mode reduce costos y complejidad en ambientes no-críticos     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Roadmap de Implementación

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        ROADMAP DE IMPLEMENTACIÓN                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   FASE 1: Fundamentos (Semana 1-2)                                          │
│   ├── Instalar ArgoCD en cluster                                            │
│   ├── Configurar ApplicationSet para Kong                                   │
│   ├── Migrar Kong a gestión via ArgoCD                                      │
│   └── Configurar External Secrets Operator                                  │
│                                                                              │
│   FASE 2: Redis HA (Semana 2-3)                                             │
│   ├── Deploy Redis Sentinel (dev/staging)                                   │
│   ├── Provisionar ElastiCache (prod)                                        │
│   ├── Configurar Kong rate-limiting plugin                                  │
│   └── Test de failover                                                      │
│                                                                              │
│   FASE 3: Multi-AZ & Resiliencia (Semana 3-4)                              │
│   ├── Configurar topologySpreadConstraints                                  │
│   ├── Habilitar IP mode (prod) / Instance mode (dev)                       │
│   ├── Configurar PodDisruptionBudget                                        │
│   └── Test de chaos engineering (kill pods/nodes)                          │
│                                                                              │
│   FASE 4: Canary (Semana 4-5)                                               │
│   ├── Instalar Flagger                                                      │
│   ├── Configurar Canary para Kong                                           │
│   ├── Integrar con Prometheus                                               │
│   └── Test de canary deployment completo                                    │
│                                                                              │
│   FASE 5: Observabilidad (Semana 5-6)                                       │
│   ├── Dashboards Grafana para Kong                                          │
│   ├── Alertas para SLOs                                                     │
│   ├── Distributed tracing                                                   │
│   └── Documentación y runbooks                                              │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Anexo: Manifiestos de Ejemplo

### Pod Topology Spread

```yaml
spec:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app.kubernetes.io/name: kong
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels:
          app.kubernetes.io/name: kong
```

### PodDisruptionBudget

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: kong-pdb
  namespace: kong
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: kong
```

---

**Documento generado:** 2026-03-26  
**Próxima revisión:** Después de implementación de Fase 1
