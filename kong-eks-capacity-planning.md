# Recomendação Técnica de Produção: Kong DB-less no AWS EKS

**Arquiteto**: SRE/Kubernetes — AWS EKS, Capacity Planning e Performance de API Gateway (Kong DB-less)
**Data**: 2026-04-22
**Contexto**: Plataforma AWS EKS com workload Kong DB-less (sem ingress controller)

---

## 1. Arquitetura Recomendada (Resumo Executivo)

**Padrão**: *Static baseline + Burst elasticity* com HA multi-AZ ativa.

- **9 nós c7i.2xlarge** distribuídos em 3 AZs (3 nós/AZ), node group dedicado por AZ
- **Kong DB-less** como workload exclusivo nos nós (taints/tolerations)
- **Baseline**: 2 pods/nó (18 pods total) — meta operacional com 33% de headroom
- **HA real**: 9 pods mínimos (3/AZ), tolera perda de 1 AZ inteira sem degradação
- **HPA**: 60% CPU target, min 6 → max 9 (limitado pela capacidade física do cluster)
- **Autoscaling de nós**: Karpenter para reposição rápida (<60s) e otimização de custo
- **CPU limits aumentados** para 3.5 vCPU (vs 2.0 atual) para eliminar throttling em burst

**Trade-off principal**: Você tem capacidade de sobra para 30K RPS (cluster suporta ~270K RPS sustentáveis), mas isso é intencional para garantir HA de AZ + headroom de burst + manutenção sem stress.

---

## 2. Premissas Explícitas de Cálculo

| Premissa | Valor | Justificativa |
|----------|-------|---------------|
| RPS sustentável por pod Kong | 15.000 | Benchmark oficial Kong ~90-140K RPS, mas produção real com plugins/upstream latency tipicamente atinge 15-25% do benchmark teórico |
| Margem de segurança | 30% | Cobre burst de tráfego, latência de upstream, e overhead de plugins |
| RPS alvo + margem | 39.000 | 30.000 × 1,30 |
| Overhead sistema + agentes | 1,25 vCPU / 1,96 GiB | kubelet + container runtime + Datadog + CrowdStrike + Fluent Bit + CloudWatch + DaemonSets infra |
| Capacidade útil por nó c7i.2xlarge | 6,75 vCPU / 14,04 GiB | 8 vCPU / 16 GiB menos overhead |
| Meta operacional | 2 pods/nó | Deixa 1 pod de headroom para burst ou manutenção |
| Cenário HA (N-1 AZs) | 2 AZs sobreviventes | Cada AZ deve absorver 50% da carga total + margem |

---

## 3. Fórmulas de Dimensionamento

### 3.1 Capacidade por Nó

```
CPU_disponível = 8 vCPU - (0,5 kubelet + 0,2 Datadog + 0,1 CrowdStrike + 0,1 Fluentbit + 0,05 CW + 0,3 infra)
CPU_disponível = 6,75 vCPU

RAM_disponível = 16 GiB - (1,0 SO + 0,256 Datadog + 0,128 CrowdStrike + 0,128 Fluentbit + 0,064 CW + 0,384 infra)
RAM_disponível = 14,04 GiB
```

### 3.2 Pods por Nó (Meta Operacional)

```
Pods_por_nó = min(floor(6,75 / 2,0), floor(14,04 / 3,0)) = min(3, 4) = 3 (teórico)
Meta_operacional = 2 pods/nó (headroom intencional de 33%)
```

### 3.3 Dimensionamento RPS

```
RPS_com_margem = 30.000 × 1,30 = 39.000 RPS
Pods_mínimos = ceil(39.000 / 15.000) = 3 pods

Para HA (1 AZ fora):
RPS_por_AZ_sobrevivente = 39.000 / 2 = 19.500
Pods_por_AZ = ceil(19.500 / 15.000) = 2 pods/AZ
Total_pods_HA = 2 × 3 AZs = 6 pods (mínimo absoluto)

Recomendação conservadora: 3 pods/AZ = 9 pods total
Capacidade_com_1_AZ_fora = 6 pods × 15.000 = 90.000 RPS
Margem_HA = (90.000 / 39.000) - 1 = 131%
```

### 3.4 HPA Threshold

```
Target_CPU = 60% do request
= 60% de 2 vCPU = 1,2 vCPU médio por pod

Isso garante:
- Escalamento ANTES do burst (que vai até 3,5 vCPU)
- Margem de 40% para variação de carga
- Sem throttling porque o limit é 3,5 vCPU
```

---

## 4. Capacidade do Cluster

| Métrica | Valor |
|---------|-------|
| **Nós** | 9 (3 AZs × 3) |
| **vCPU total** | 72 vCPU |
| **RAM total** | 144 GiB |
| **Overhead agregado** | 11,25 vCPU / 17,64 GiB |
| **Capacidade útil total** | 60,75 vCPU / 126,36 GiB |
| **Pods Kong (meta 2/nó)** | 18 pods |
| **RPS sustentável (meta)** | 270.000 RPS |
| **Utilização CPU média (meta)** | ~59% por nó |
| **Headroom por nó** | 2,75 vCPU / 8,04 GiB livres |

**Observação**: Seus 30K RPS representam apenas ~11% da capacidade sustentável do cluster. Isso é **desejável** para HA, mas se o custo for crítico, considere reduzir para 6 nós (2/AZ) com Karpenter para burst elástico.

---

## 5. Estratégia de Balanceamento

### 5.1 Topology Spread Constraints (Obrigatório)
Distribui **igualdade absoluta** entre AZs e nós. Usar `maxSkew: 1` com `DoNotSchedule` garante que nenhum domínio fique desbalanceado.

### 5.2 Pod Anti-Affinity (Hard)
Impede 2 pods Kong no mesmo nó. Essencial para:
- Isolamento de falha de nó
- Eliminação de contenção de CPU/RAM
- Garantia que HPA scale realmente para novos nós

### 5.3 PodDisruptionBudget
Garante que durante deploys, drains ou upgrades, no mínimo 85% dos pods fiquem disponíveis (8/9 em operação).

### 5.4 Rolling Update
- `maxSurge: 1` — evita picos de recurso durante deploy
- `maxUnavailable: 1` — mantém 8/9 pods ativos
- `terminationGracePeriodSeconds: 60` — Kong precisa drenar conexões ativas

---

## 6. Estratégia de Autoscaling

### 6.1 HPA (Horizontal Pod Autoscaler)

| Parâmetro | Valor | Justificativa |
|-----------|-------|---------------|
| Métrica | CPU utilization | Métrica nativa, baixa latência |
| Target | 60% | Escalamento antes do burst real |
| Min replicas | 6 (2/AZ) | HA mínima, tolera falha de 1 AZ |
| Max replicas | 9 (3/AZ) | Capacidade total do cluster |
| Behavior | scaleUp: 60s stabilization | Evita flapping em spike |
| Behavior | scaleDown: 300s stabilization | Espera tráfego estabilizar |

**Por que não usar métricas customizadas (RPS)?**
HPA com métricas customizadas (Kong RPS via Prometheus Adapter) tem latência de scraping + cálculo. CPU é mais reativo para burst de tráfego. Use RPS como métrica secundária/alerta, não primária de scaling.

### 6.2 Autoscaler de Nós: Karpenter (Recomendado)

**Por que Karpenter ao invés de Cluster Autoscaler?**

| Aspecto | Karpenter | Cluster Autoscaler |
|---------|-----------|-------------------|
| **Tempo de provisão** | 30-60 segundos | 3-5 minutos |
| **Modelo** | Event-driven (imediato) | Scan periódico (10s+) |
| **Bin-packing** | Right-sizing dinâmico | Tamanho fixo do ASG |
| **Spot** | Mix nativo On-Demand/Spot | Configuração manual por ASG |
| **Consolidação** | Automática (remoção de nós subutilizados) | Limitada |

**Configuração recomendada**:
- NodePool com `taint` dedicado para Kong (`dedicated=kong:NoSchedule`)
- `consolidation.enabled: true` — remove nós subutilizados automaticamente
- `terminationGracePeriod: 30m` — respeita PDBs durante consolidação
- `weight: 10` para On-Demand, `weight: 90` para Spot (se aceitável para API Gateway)

**Limites**:
- Min nós: 3 (1/AZ — cluster mínimo operacional)
- Max nós: 12 (4/AZ — headroom para manutenção + burst)
- **Nota**: Seu cluster atual de 9 nós é estático. Karpenter gerencia reposição, não expansão além do max.

---

## 7. Explicação: Por que CPU Ultrapassa 2 vCPU?

Você observou pods com "2 vCPU" chegando a **2,8–3 vCPU**. Isso é esperado e explicável:

### 7.1 CFS Bandwidth Controller (cgroups v1/v2)
Kubernetes CPU limits usam o **Completely Fair Scheduler (CFS)** do Linux. O kernel aloca time slices em períodos de 100ms:

- Limit = 2 vCPU → quota = 200ms a cada 100ms
- Se o processo usar 250ms em 100ms → **throttling** nos 50ms restantes
- Mas o `container_cpu_cfs_throttled_seconds_total` só aparece se houver contenção

### 7.2 Por Que o Uso "Aparece" > 2 vCPU?
1. **Métrica de CPU é média no intervalo de scraping** (geralmente 15-30s). Se o pod usa 0ms por 700ms e 400ms por 300ms, a média é 120% do limit.
2. **Kong é single-threaded por worker** — múltiplos workers (tipicamente 1 por vCPU) competem por CPU em bursts de requisições.
3. **LuaJIT + OpenResty** — o worker process do Nginx pode saturar um core por alguns milissegundos processando headers, plugins, etc.

### 7.3 Solução: Aumentar o Limit (Não o Request)
- **Request continua 2 vCPU** — scheduling estável, kube-scheduler aloca corretamente
- **Limit aumenta para 3,5 vCPU** — elimina throttling em burst, dá margem para spikes de 100ms
- **HPA target em 60%** — escala antes de o pod precisar do burst constante

**Risco de não ajustar**: Throttling causa latência de cauda longa (P99/P95 degradam) sem o pod aparentar estar sobrecarregado no dashboard de 1-minuto.

---

## 8. Configuração Resiliente para Falha de AZ

### 8.1 Requisitos para HA Real
1. **Mínimo 3 AZs** com pods distribuídos igualmente
2. **Cada AZ deve ser autossuficiente** para 50% da carga + margem
3. **Load Balancer (NLB/ALB)** com health checks agressivos e cross-zone load balancing desabilitado (ou habilitado, dependendo da estratégia)

### 8.2 Estratégia de Load Balancing
- **NLB com target groups por AZ** — se 1 AZ falha, o NLB redireciona para AZs saudáveis
- **Health check interval: 10s**, threshold: 2 unhealthy
- **Cross-zone load balancing: DISABLED** — mantém tráfego local à AZ, reduzindo blast radius

### 8.3 Kong DB-less Specific
- Como não usa banco, não há dependência de RDS/Aurora multi-AZ
- Configuração via ConfigMap/Secret — replicada em todas as AZs
- **Cuidado**: Se usar rate-limiting local (memória), o estado não é compartilhado entre pods. Para HA real, use rate-limiting distribuído (Redis) ou aceite que o limite é por-pod.

---

## 9. Manifests Kubernetes (Prontos para Produção)

### 9.1 ConfigMap (Kong DB-less declarative)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kong-declarative-config
  namespace: kong
data:
  kong.yml: |
    _format_version: "3.0"
    services:
      - name: upstream-api
        url: http://upstream-service.namespace.svc.cluster.local
        routes:
          - name: api-route
            paths:
              - /api
    plugins:
      - name: rate-limiting
        config:
          minute: 1000
          policy: local  # ATENÇÃO: local = por pod. Use redis para cluster-wide
```

### 9.2 Deployment (Com Anti-Affinity + Topology Spread)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kong-gateway
  namespace: kong
  labels:
    app: kong-gateway
    tier: edge
spec:
  replicas: 9  # 3 por AZ, ajustado pelo HPA depois
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
  selector:
    matchLabels:
      app: kong-gateway
  template:
    metadata:
      labels:
        app: kong-gateway
        tier: edge
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8100"
    spec:
      # === TOPOLOGY SPREAD: Distribuição equilibrada ===
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: kong-gateway
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: kong-gateway

      # === ANTI-AFFINITY: Nunca 2 Kong no mesmo nó ===
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - kong-gateway
              topologyKey: kubernetes.io/hostname

      # === TOLERATIONS: Nós dedicados ===
      tolerations:
        - key: "dedicated"
          operator: "Equal"
          value: "kong"
          effect: "NoSchedule"

      containers:
        - name: kong
          image: kong:3.5  # Use versão pinned, não latest
          env:
            - name: KONG_DATABASE
              value: "off"
            - name: KONG_DECLARATIVE_CONFIG
              value: "/kong/declarative/kong.yml"
            - name: KONG_PROXY_ACCESS_LOG
              value: "/dev/stdout"
            - name: KONG_ADMIN_ACCESS_LOG
              value: "/dev/stdout"
            - name: KONG_PROXY_ERROR_LOG
              value: "/dev/stderr"
            - name: KONG_ADMIN_ERROR_LOG
              value: "/dev/stderr"
            - name: KONG_PLUGINS
              value: "bundled,rate-limiting"
            # Workers = vCPU disponível (ajuste conforme limit)
            - name: KONG_NGINX_WORKER_PROCESSES
              value: "2"  # Igual ao CPU request

          ports:
            - name: proxy
              containerPort: 8000
              protocol: TCP
            - name: proxy-ssl
              containerPort: 8443
              protocol: TCP
            - name: admin
              containerPort: 8100  # Admin API em porta alternativa, não exposta externamente
              protocol: TCP

          resources:
            requests:
              cpu: "2000m"      # 2 vCPU — scheduling estável
              memory: "3Gi"     # Baseline Kong DB-less
            limits:
              cpu: "3500m"      # 3.5 vCPU — elimina throttling em burst
              memory: "4Gi"     # Margem para conexões e plugins

          livenessProbe:
            httpGet:
              path: /status
              port: admin
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3

          readinessProbe:
            httpGet:
              path: /status/ready
              port: admin
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 2

          volumeMounts:
            - name: declarative-config
              mountPath: /kong/declarative

          lifecycle:
            preStop:
              exec:
                # Drena conexões ativas antes de terminar
                command: ["/bin/sh", "-c", "sleep 15 && kong quit"]

      volumes:
        - name: declarative-config
          configMap:
            name: kong-declarative-config

      terminationGracePeriodSeconds: 60
```

### 9.3 HPA (Horizontal Pod Autoscaler)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: kong-gateway-hpa
  namespace: kong
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: kong-gateway
  minReplicas: 6      # HA mínimo: 2 por AZ
  maxReplicas: 9      # Capacidade total do cluster (3 por AZ)
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60  # 1.2 vCPU médio (60% de 2vCPU)
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Percent
          value: 100
          periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 300  # 5 minutos antes de reduzir
      policies:
        - type: Percent
          value: 10
          periodSeconds: 60
```

### 9.4 PDB (PodDisruptionBudget)

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: kong-gateway-pdb
  namespace: kong
spec:
  minAvailable: 8     # 89% disponível (8/9 pods)
  selector:
    matchLabels:
      app: kong-gateway
```

**Justificativa do minAvailable: 8**: Com 9 pods, permitir apenas 1 indisponível garante que durante:
- Rolling updates: máximo 1 pod novo + 1 old por vez
- Node drains: Kubernetes espera o novo pod ficar ready antes de drenar o próximo
- Falha de AZ: se 3 pods caem, o PDB impede evicções adicionais até recuperação

---

## 10. Checklist de Validação Pós-Deploy

### 10.1 Verificação de Distribuição por AZ

```bash
# Verificar distribuição equilibrada
kubectl get pods -n kong -o wide -l app=kong-gateway | awk '{print $7}' | sort | uniq -c

# Esperado: ~3 pods por nó, 1 nó por AZ (exemplo)
#   3 ip-10-0-1-10.us-east-1a.internal
#   3 ip-10-0-2-20.us-east-1b.internal  
#   3 ip-10-0-3-30.us-east-1c.internal

# Verificar topology spread
kubectl get pods -n kong -o json | jq -r '.items[] | "\(.metadata.name) \(.spec.nodeName)"' | sort
```

### 10.2 Verificação de Anti-Affinity

```bash
# Confirmar que nenhum nó tem >1 pod Kong
kubectl get pods -n kong -o wide -l app=kong-gateway | awk 'NR>1 {print $7}' | sort | uniq -d

# Esperado: vazio (sem duplicatas)
```

### 10.3 Stress Test e Validação de HPA

```bash
# 1. Gerar carga com k6/vegeta para 30K RPS
# 2. Monitorar HPA:
watch kubectl get hpa -n kong

# Esperado: 
# - Abaixo de 60% CPU: 6 replicas
# - Acima de 60% por 60s: escala para 7, 8, 9
# - Após carga: mantém 5 minutos, depois desescala

# 3. Verificar throttling:
kubectl top pod -n kong
# Ou via metrics-server/prometheus:
# container_cpu_cfs_throttled_periods_total / container_cpu_cfs_periods_total < 10%
```

### 10.4 Simulação de Falha de AZ

```bash
# 1. Cordon todos os nós de 1 AZ
kubectl cordon $(kubectl get nodes -l topology.kubernetes.io/zone=us-east-1a -o name)

# 2. Evacuar pods (respeita PDB)
kubectl drain --ignore-daemonsets --delete-emptydir-data $(kubectl get nodes -l topology.kubernetes.io/zone=us-east-1a -o name)

# 3. Verificar se pods foram recriados nas outras AZs
kubectl get pods -n kong -o wide -l app=kong-gateway

# 4. Validar que PDB não permite <8 pods disponíveis
kubectl get pdb -n kong

# 5. Medir RPS sustentável nas 2 AZs restantes (deve manter 30K+)
```

### 10.5 Validação de Rolling Update

```bash
# Trigger deploy
kubectl rollout restart deployment/kong-gateway -n kong

# Monitorar:
kubectl rollout status deployment/kong-gateway -n kong
# Esperado: ~30-60s por pod, máximo 1 pod unavailable

# Verificar distribuição após deploy
kubectl get pods -n kong -o wide -l app=kong-gateway | awk '{print $7}' | sort | uniq -c
# Esperado: ainda balanceado, não concentrado em poucos nós
```

### 10.6 Métricas Críticas para Alerta

| Métrica | Threshold | Ação |
|---------|-----------|------|
| `container_cpu_cfs_throttled_periods_total` / periods > 10% | Warning | Aumentar CPU limit |
| `kong_http_requests_total` (RPS) / pod > 20K | Warning | Reavaliar capacidade por pod |
| `container_memory_usage_bytes` / limit > 85% | Critical | Aumentar RAM limit ou investigar leak |
| `kube_pod_status_ready` < 8 | Critical | PDB violado, investigar scheduling |
| `node_cpu_utilization` > 80% por 5min | Warning | Karpenter deve provisionar nó, se não, investigar |

---

## 11. Riscos Operacionais e Trade-offs

| Risco | Mitigação |
|-------|-----------|
| **Over-provisioning de 9 nós para 30K RPS** | Custo alto, mas garante HA. Alternativa: 6 nós (2/AZ) + Karpenter para burst elástico |
| **Karpenter com Spot instances** | Spot pode ser interrompido. Use 100% On-Demand para API Gateway ou mix 70/30 com fallback |
| **Rate-limiting local (memória)** | Limite é por-pod, não global. Use Redis para consistência cluster-wide |
| **CPU limit 3,5 vCPU sem request equivalente** | Pod pode monopolizar CPU do nó em burst. Mitigação: meta de 2 pods/nó deixa headroom |
| **Topology spread com DoNotSchedule** | Se um AZ perde todos os nós, novos pods não schedulam até reposição. Mantenha min 1 nó/AZ |
| **HPA max=9 limitado pelo cluster** | Se 30K RPS crescer, cluster não escala horizontalmente. Monitorar e planejar expansão |

---

## 12. Resumo da Recomendação

| Componente | Configuração |
|------------|--------------|
| **CPU Request/Limit** | 2 vCPU / 3,5 vCPU |
| **RAM Request/Limit** | 3 GiB / 4 GiB |
| **Replicas (baseline)** | 9 (3/AZ) |
| **HPA Min/Max** | 6 / 9 |
| **HPA Target** | 60% CPU |
| **Topology Spread** | maxSkew=1, zone + hostname, DoNotSchedule |
| **Anti-Affinity** | Hard, hostname level |
| **PDB** | minAvailable=8 |
| **Rolling Update** | maxSurge=1, maxUnavailable=1 |
| **Autoscaler de Nós** | Karpenter, min 3 nós, max 12 |
| **Capacidade para 30K RPS** | 131% de margem em HA (90K RPS com 1 AZ fora) |

**Próximo passo imediato**: Aplique os manifests acima em staging, execute o checklist de validação, e monitore `container_cpu_cfs_throttled_periods_total` por 24h antes de promover para produção.
