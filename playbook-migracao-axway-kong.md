# Playbook: Migração Axway API Gateway → Kong Gateway (EKS/AWS)

---

## 1. Visão Geral & Arquitetura Alvo

```
┌─────────────────┐     ┌─────────────────┐     ┌──────────────────┐
│   Consumidores  │────▶│  Kong Gateway   │────▶│   EKS Services   │
│  (Apps/Parceiros│     │  (Data Plane)   │     │  (.NET / Java)   │
│   /Internos)    │     │  + Control Plane│     │  on EC2 (Linux)  │
└─────────────────┘     └─────────────────┘     └──────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌─────────────▼─────────────┐
                    │   Datadog (Unified)       │
                    │  APM / Traces / Logs /    │
                    │  Metrics / Synthetics     │
                    └───────────────────────────┘
```

**Padrão Arquitetural:**
- **Kong Gateway** como único ponto de entrada no cluster (sem Ingress Controller nativo).
- Kong atua como `LoadBalancer` Service (NLB/ALB via AWS Load Balancer Controller) ou como `NodePort` com ALB externo.
- Backends .NET e Java coexistem em EC2 Linux (fase de transição) e são descobertos via **Service Endpoints** ou **ExternalName** no EKS.
- O Kong roteia para o endpoint do EC2 diretamente (ou via TargetGroup Binding).

---

## 2. Premissas & Limitações

| # | Premissa |
|---|----------|
| 1 | EKS já provisionado com IRSA, VPC CNI e AWS Load Balancer Controller. |
| 2 | EC2 Linux já acessível via Security Groups pelo range de nodes do EKS. |
| 3 | Kong Gateway Enterprise ou OSS 3.x+ com Helm chart oficial. |
| 4 | TLS terminado no Kong (ou pass-through se exigir mTLS de cliente). |
| 5 | CI/CD já capaz de deployar manifests no EKS. |
| 6 | **Datadog Agent** instalado no EKS (DaemonSet) e nas EC2 Linux (APM/Logs/Metrics ativos). |
| 7 | **Datadog API Key** e **APM** habilitados na conta e no agente. |

| # | Limitação |
|---|-----------|
| 1 | Sem Ingress: todo roteamento é declarado via CRDs `KongIngress`, `TCPIngress` ou `HTTPRoute` (Gateway API). |
| 2 | EC2 não é dinâmico: mudanças de IP/instância exigem atualização de Endpoints ou DNS. |
| 3 | .NET e Java compartilham a mesma camada de rede; isolamento é apenas via Kong routing/policies. |
| 4 | Kong OSS não tem Developer Portal nativo; uso de DevPortal só com Enterprise. |

---

## 3. Estratégia por Fases

| Fase | Nome | Duração Est. | Objetivo |
|------|------|--------------|----------|
| 0 | **Base & Discovery** | 3-5 dias | Instalar Kong, mapear APIs Axway, configurar observabilidade. |
| 1 | **Shadow & Validate** | 1-2 semanas | Kong espelha tráfego (mirror) ou roteia 0% produtivo; valida contratos. |
| 2 | **Canary 5% → 25%** | 1 semana | Migrar consumidores internos/low-risk; monitorar SLOs. |
| 3 | **Canary 50% → 75%** | 1 semana | Migrar consumidores externos de baixo volume. |
| 4 | **Full Cutover** | 2-3 dias | 100% no Kong; Axway em modo leitura/backup. |
| 5 | **Decommission** | 1-2 semanas | Remover Axway, ajustar DNS, documentar lições. |

---

## 4. Rollout Percentual de Consumidores

### Critérios de Avanço (Go/No-Go)

| Métrica | Limite de Sucesso | Ferramenta |
|---------|-------------------|------------|
| Latência p95 | < baseline Axway + 20% | Datadog Metrics (Kong + ALB) |
| Taxa de Erro 5xx | < 0.5% | Datadog Metrics + Kong access logs |
| Latência de autenticação (JWT/mTLS) | < 100ms | Datadog APM (trace span do Kong → backend) |
| Logs de erro por minuto | < threshold baseline | Datadog Logs (faceted por service/status) |
| SLO de disponibilidade | > 99.9% | Datadog Synthetics (API Tests) |

### Critérios de Rollback (Imediato)

| Gatilho | Ação |
|---------|------|
| 5xx > 2% por mais de 3 min | Rollback automático via flag de roteamento (Kong Route weight 0%). |
| Latência p99 > 5s por 5 min | Rollback + página on-call. |
| Falha de autenticação > 10% | Verificar Kong Plugin (JWT/OAuth2) + rollback. |

### Mecânica de Roteamento Percentual

Use **Kong Route com `headers` ou `snis`** ou controle via **traffic splitting** com service mesh (ex: Istio/Linkerd) ou simplesmente dois `KongIngress` com pesos:

```yaml
# Exemplo: 10% para Kong, 90% Axway (via ExternalName ou NLB)
plugins:
- name: proxy-cache  # se necessário
services:
- name: legacy-axway
  url: http://axway-nlb.amazonaws.com
  routes:
  - name: axway-route
    paths: ["/api/v1"]
    headers:
      X-Migration-Pool: ["legacy"]
- name: new-kong-backend
  url: http://dotnet-java-ec2.local
  routes:
  - name: kong-route
    paths: ["/api/v1"]
    headers:
      X-Migration-Pool: ["kong"]
```

> **Alternativa mais simples:** controle percentual no cliente injetando header `X-Canary: 10` e usar Kong plugin `canary` ou rate-limiting condicional.

---

## 5. Observabilidade (Stack Datadog)

| Camada | O Que | Como | Onde |
|--------|-------|------|------|
| **Métricas** | Latência, RPS, 5xx, CPU/memória Kong, ALB | Datadog Agent (DaemonSet) coleta do Kong e do host. DogStatsD via UDP 8125. Métricas custom do Kong via `datadog` plugin ou StatsD. | EKS / Kong Admin / EC2 |
| **Logs** | Access logs, erro de plugins, trace de request | Datadog Agent tail de `/dev/stdout` dos pods Kong + logs das EC2 Linux. Parse automático de JSON/NGINX. | Todos os pods Kong + EC2 |
| **Traces** | Distributed tracing end-to-end | Kong OpenTelemetry → Datadog Agent OTLP ingest **ou** Kong `datadog` tracing plugin (via `ddtrace`). Aplicações .NET/Java instrumentadas com Datadog APM agents. | Kong + .NET + Java |
| **APM** | Performance de código .NET/Java | Datadog APM agents (dd-trace-dotnet, dd-trace-java) nas EC2 Linux + containers. Flame graphs e service map. | EC2 Linux + EKS workloads |
| **Synthetics** | Health check de APIs críticas | Datadog Synthetics (API Tests + Multistep) monitorando endpoints públicos do Kong. | Endpoints públicos |
| **Alertas** | Paging por SLO | Datadog Monitors → PagerDuty / Slack. Thresholds em métricas e logs. | On-call |

### Configuração Essencial no Kong Helm (Datadog)

```yaml
# values.yaml excerpt
env:
  proxy_access_log: /dev/stdout
  admin_access_log: /dev/stdout
  # Envia traces para Datadog Agent via OTLP ou DogStatsD
  tracing_instrumentations: all
  tracing_sampling_rate: 0.1  # ajustar conforme volume
  # Se usar plugin datadog (legacy StatsD):
  # plugins: bundled,datadog

plugins:
  configMap:
    enabled: true
    name: kong-plugins

# Datadog Agent já deve estar no cluster com:
# - DD_APM_ENABLED=true
# - DD_OTLP_CONFIG_TRACES_ENABLED=true  (para OTLP ingest)
# - DD_LOGS_ENABLED=true
# - DD_PROCESS_AGENT_ENABLED=true
```

#### KongPlugin para Métricas (Datadog StatsD)

```yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: datadog-metrics
plugin: datadog
config:
  host: "$(DATADOG_AGENT_HOST)"  # via downward API ou DNS local
  port: 8125
  metrics:
    - name: latency
      stat_type: timer
      sample_rate: 1
      consumer_identifier: consumer_id
    - name: request_count
      stat_type: counter
      sample_rate: 1
    - name: status_count
      stat_type: counter
      sample_rate: 1
```

#### Instrumentação APM nas EC2 Linux

```bash
# .NET (Linux x64)
DD_AGENT_HOST=localhost DD_TRACE_AGENT_PORT=8126 \
  dotnet meu-app.dll

# Java
java -javaagent:/opt/datadog/dd-java-agent.jar \
  -Ddd.service=meu-backend-java \
  -Ddd.env=producao \
  -Ddd.version=1.2.3 \
  -jar meu-app.jar
```

---

## 6. Testes

| Tipo | Escopo | Responsável | Ferramenta |
|------|--------|-------------|------------|
| **Contrato** | Schema OpenAPI/Swagger da Axway vs Kong | QA / Dev | Schemathesis / Dredd |
| **Carga** | Validar se Kong aguenta throughput Axway | Performance | k6 / Artillery / JMeter |
| **Segurança** | JWT, mTLS, Rate Limiting, WAF bypass | Security | OWASP ZAP + Kong policies |
| **Chaos** | Falha de pod Kong, timeout EC2 | SRE | Litmus / Gremlin |
| **Smoke Pós-Migração** | 30 min após cada fase | SRE | Postman / Newman em pipeline |

### Cenários Críticos de Teste

1. **Auth Parity:** Token gerado na Axway deve ser aceito pelo Kong (validar JWKS/issuer).
2. **Rate Limit:** Axway limitava 1000 req/min; Kong plugin `rate-limiting` ou `rate-limiting-advanced` deve replicar.
3. **Transformação:** Se Axway transformava headers/body, o Kong plugin `request-transformer` deve replicar 1:1.

---

## 7. Riscos & Mitigações

| Risco | Impacto | Prob. | Mitigação |
|-------|---------|-------|-----------|
| Divergência de autenticação (OAuth2/JWT) | Alto | Média | Teste de contrato de auth na Fase 0; manter JWKS igual. |
| Timeout/latência EC2 por novo roteamento | Médio | Média | Circuit Breaker (Kong `proxy-cache` + retries configurados). |
| Perda de logs/auditoria da Axway | Alto | Baixa | Exportar logs Axway para S3 antes do cutover. |
| Plugin Kong incompatível com payload .NET | Médio | Média | Fase Shadow com tráfego real espelhado. |
| Falha de DNS/NLB no cutover | Alto | Baixa | Blue/Green DNS com TTL baixo (30s); rollback reverte DNS. |
| On-call despreparado para debug Kong | Médio | Média | Runbook + dry-run de incidente na Fase 1. |

---

## 8. Runbook Operacional

### 8.1. Rollback Manual (Emergência)

```bash
# 1. Verificar status atual
kubectl get kongingress -n kong

# 2. Redirecionar 100% para Axway (alterar weight ou header default)
kubectl patch kongingress api-v1 --type=merge -p \
  '{"proxy":{"connect_timeout":60000,"retries":5}}'

# 3. Escalar pods Kong para zero (se necessário isolar)
kubectl scale deployment kong-gateway -n kong --replicas=0

# 4. Validar DNS apontando para Axway NLB
aws route53 change-resource-record-sets --hosted-zone-id ZXXX ...
```

### 8.2. Diagnóstico de Erro 5xx no Kong

```bash
# Logs em tempo real (Datadog)
# Facetar no Datadog Logs: source:kong status:500,502,503 @service:meu-servico

# Logs local (fallback)
kubectl logs -n kong -l app=kong-gateway --tail=100 -f | grep "500\|502\|503"

# Verificar upstream health
curl -s http://localhost:8001/upstreams | jq '.data[].health'

# Testar rota específica internamente
curl -i http://kong-proxy:80/api/v1/health -H "Host: api.empresa.com"

# Datadog APM: filtrar trace por `service:kong` + `error:true` para ver stack trace e span tags
```

### 8.3. Hotfix de Plugin

```bash
# Desabilitar plugin rapidamente
kubectl patch kongplugin rate-limit-api -n kong --type=merge -p '{"disabled":true}'
```

---

## 9. RACI

| Atividade | Product Owner | Arquiteto | SRE | Dev Backend | QA | Security |
|-----------|:-------------:|:---------:|:---:|:-----------:|:--:|:--------:|
| Definir arquitetura alvo | C | R/A | C | C | I | C |
| Instalar/Configurar Kong | I | A | R | C | I | C |
| Mapear APIs Axway → Kong | C | A | C | R | C | I |
| Configurar plugins (auth, rate limit) | I | A | R | C | I | R |
| Testes de carga/contrato | I | C | C | C | R/A | I |
| Rollout percentual | A | C | R | C | C | I |
| Monitoramento/Alertas | I | C | R/A | I | I | C |
| Rollback emergencial | A | C | R | C | I | I |
| Decommission Axway | A | C | R | I | I | C |

> **R** = Responsável (faz) | **A** = Aprovador / Accountable | **C** = Consultado | **I** = Informado

---

## 10. Cronograma Resumido (Sugestão 5 Semanas)

| Semana | Atividades |
|--------|------------|
| **Semana 1** | Fase 0: Provisionar Kong, observabilidade, mapear 100% APIs, testes de contrato. |
| **Semana 2** | Fase 1: Shadow traffic, ajuste de plugins, dry-run de rollback, treinamento on-call. |
| **Semana 3** | Fase 2: Canary 5% → 25% (internos), monitoramento intensivo. |
| **Semana 4** | Fase 3: Canary 50% → 75% (externos), validar SLOs. |
| **Semana 5** | Fase 4: 100% cutover + Fase 5: Decommission Axway (2a quinzena). |

---

## 11. Tabela de Acompanhamento da Migração

Use esta tabela para acompanhamento semanal de cada API/Consumer.

| API/Consumer | Dono | Fase Atual | % no Kong | Latência p95 | Erro 5xx | Status | Data Cutover | Observação |
|--------------|------|------------|-----------|--------------|----------|--------|--------------|------------|
| `api-pagamentos` | Time A | 2 | 25% | 45ms | 0.1% | 🟢 | - | OK, avançar para 50% |
| `api-cadastro` | Time B | 1 | 0% | — | — | 🟡 | - | Aguardando fix de CORS |
| `api-relatorios` | Time C | 3 | 75% | 120ms | 0.8% | 🟠 | - | Erro elevado, investigar |
| `parceiro-x` | Ext | 0 | 0% | — | — | ⚪ | - | Dependência de mTLS |

**Legenda:** 🟢 On Track | 🟡 Atenção | 🟠 Bloqueado | ⚪ Não iniciado | 🔴 Rollback executado

---

## 12. Próximos 7 Dias (Plano de Ação Imediato)

| Dia | Ação | Responsável | Entregável |
|-----|------|-------------|------------|
| **Dia 1** | Kickoff técnico + validar acesso EKS/EC2 | Arquiteto / SRE | Acesso confirmado, IAM ok |
| **Dia 2** | Deploy Kong via Helm no EKS (modo DB-less ou Postgres) | SRE | Kong Admin UI/endpoint no ar |
| **Dia 3** | Mapear 10 APIs críticas do Axway para manifestos Kong | Dev Backend | YAMLs de `KongIngress`/`Services` |
| **Dia 4** | Configurar Datadog Logs, Metrics, APM e Synthetics no Kong + EC2 | SRE | Dashboard baseline no Datadog; service map visível |
| **Dia 5** | Teste de carga baseline no Axway (para comparar depois) | QA | Relatório de throughput/latência |
| **Dia 6** | Shadow traffic: Kong espelhando 1 API sem afetar prod | SRE / Dev | Logs validados, sem drift |
| **Dia 7** | Revisão Go/No-Go para iniciar Canary 5% | Todos | Decisão documentada, runbook testado |

---

## Anexos Sugeridos (criar após aprovação)

1. **Manifestos YAML:** `kong-values.yaml`, `externalname-ec2.yaml`, `kong-plugins/`.
2. **Runbook detalhado:** Markdown no repositório Git (`/docs/runbooks/kong-migration.md`).
3. **Dashboards:** JSON export do **Datadog** (screenboards/timeboards) para Kong + Backends.
4. **Planilha de Acompanhamento:** Google Sheets / Excel compartilhado com times.
5. **Monitores Datadog:** Definição como código (Terraform ou API) para latência, 5xx, Synthetics failed tests.
