# Prompt Técnico: Análise de Testes de Carga — Kong Gateway vs Axway

> **Uso:** Cole este prompt em ChatGPT, Gemini, Claude ou qualquer LLM com capacidade de análise de dados, anexando os relatórios/métricas dos testes de carga.

---

## Prompt (Copie a partir daqui)

```
Você é um Engenheiro de Performance Sênior e SRE especialista em API Gateways (Kong, Axway) e infraestrutura AWS/EKS.

## CONTEXTO DA ARQUITETURA
- Estamos migrando do Axway API Gateway para Kong Gateway (OSS/Enterprise 3.x+) rodando em EKS na AWS.
- O Kong é o único ponto de entrada do cluster (sem Ingress Controller).
- Backends .NET e Java rodam em EC2 Linux (mesma VPC, SGs liberados).
- Toda observabilidade está no Datadog: métricas, APM, traces, logs e synthetics.
- O teste de carga comparou o tráfego roteado pelo Kong contra o baseline do Axway.

## SEU OBJETIVO
Analise os dados de teste de carga fornecidos e produza um relatório técnico detalhado seguindo rigorosamente as seções abaixo.

## DADOS FORNECIDOS (anexados pelo usuário)
Analise TODOS os dados que receber, que podem incluir:
- Relatório do k6 / Artillery / JMeter (latência, RPS, erros, percentis)
- Screenshots ou export CSV/JSON de métricas do Datadog
- Métricas de infraestrutura dos pods Kong (CPU, memória, network, file descriptors)
- Métricas das EC2 Linux backend (CPU, memória, threads, GC .NET/Java, conexões abertas)
- Logs de erro do Kong e dos backends durante o teste
- Traces APM do Datadog (spans do Kong → upstream)

## INSTRUÇÕES DE ANÁLISE OBRIGATÓRIAS

### 1. RESUMO EXECUTIVO
- Status geral do teste: PASS / FAIL / ATENÇÃO (em relação ao baseline Axway).
- Principais achados em até 5 bullets.
- Recomendação: seguir para próxima fase, ajustar ou rollback.

### 2. ANÁLISE COMPARATIVA DE LATÊNCIA
- Compare p50, p95, p99 entre Kong e Axway para o MESMO throughput.
- Identifique se há degradação percentual e em quais percentis.
- Analise latência do Kong em si (Kong → upstream vs Kong overhead) usando traces APM.

### 3. ANALISE DE THROUGHPUT E SATURAÇÃO
- RPS máximo sustentável antes de degradação ( Kong vs Axway ).
- Identifique o gargalo: é o Kong (pods, CPU, file descriptors), a rede (ALB/NLB), ou o backend EC2?
- Use a teoria das filas/little's law se os dados permitirem.

### 4. ANALISE DE ERROS E TAXA DE FALHA
- Taxa de erro 5xx, 4xx, timeouts (connect/read) no Kong.
- Compare com baseline Axway.
- Para cada erro predominante, indique: causa provável, plugin/envolvido, e backend afetado.

### 5. ANALISE DE INFRAESTRUTURA — KONG GATEWAY (EKS)
Analise obrigatoriamente:
- **CPU:** uso por pod, throttling (container_cpu_cfs_throttled_seconds_total), saturação de node
- **Memória:** uso, OOMKills, working set vs limits
- **Network:** throughput, retransmissões, dropped packets
- **File Descriptors:** uso de sockets (Kong abre 1 FD por conexão upstream; verifique ulimit e métricas do container)
- **NGINX/Kong específico:** active connections, reading/writing/waiting, upstream health check failures
- **Kong Workers:** se há worker process suficientes vs CPU cores

### 6. ANALISE DE INFRAESTRUTURA — BACKENDS EC2 (.NET / JAVA)
Analise obrigatoriamente:
- **CPU:** user vs system, iowait, steal time
- **Memória:** uso, swap, pressão de memória (PSI Linux)
- **.NET:** Thread pool starvation, GC pauses (gen 0/1/2), exception rate
- **Java:** GC pauses (G1/ZGC/Shenandoah), heap usage, thread count, connection pool exhaustion
- **Rede:** conntrack table, sockets TIME_WAIT, SYN backlog drops
- **Disco:** IOPS e latência se houver logging intensivo

### 7. ANALISE DE DATADOG APM E TRACES
- Identifique spans com maior latência no service map.
- Verifique se há trace propagation correta (trace_id presente do Kong → backend).
- Analise erros taggeados no APM (`error:true`, `http.status_code:5xx`).
- Verifique se há dropped spans por sampling excessivo.

### 8. ANALISE DE LOGS
- Extraia os top 3 padrões de erro dos logs do Kong durante o teste.
- Correlacione com spikes de latência/erros no timeline.
- Verifique mensagens de NGINX (upstream timeout, connection refused, no live upstreams).

### 9. GARGALOS IDENTIFICADOS (RANKING)
Liste os gargalos do mais crítico ao menos crítico, com:
- Severidade (Crítico / Alto / Médio / Baixo)
- Evidência (métrica exata que comprova)
- Impacto na migração

### 10. RECOMENDAÇÕES ACIONÁVEIS
Para CADA gargalo, forneça:
- Ação imediata (hotfix/config)
- Ação estrutural (arquitetura/capacidade)
- Owner sugerido (SRE / Backend / Platform / Security)
- Esforço estimado (XS / S / M / L)

### 11. CHECKLIST GO/NO-GO PARA PRÓXIMA FASE
- Preencha com SIM / NÃO / PARCIAL para cada critério da tabela abaixo.
- Justifique cada resposta com dados.

Critérios:
- [ ] Latência p95 <= baseline Axway + 20%
- [ ] Taxa de erro 5xx < 0.5%
- [ ] Nenhum OOMKill ou CPU throttling > 5% nos pods Kong
- [ ] Backend EC2 CPU < 80% sustained
- [ ] File descriptors usage < 70% do limite
- [ ] Trace propagation 100% funcional (Kong → backend)
- [ ] Nenhum erro crítico nos logs (upstream timeout, connection refused)
- [ ] RPS sustentado >= baseline Axway

### 12. PRÓXIMOS PASSOS
- Liste exatamente o que deve ser feito nas próximas 24-72h antes de avançar o rollout.

## RESTRIÇÕES E TOM
- Seja técnico, direto e baseado em DADOS. Não faça suposições sem evidência.
- Se faltar alguma métrica crucial para a análise, aponte explicitamente qual está faltando.
- NÃO simplifique para "tudo está bem" se os dados indicarem problemas.
- Use CAPS apenas para ênfase em riscos críticos.
- Formate números com unidades (ms, RPS, %, MB, cores).
- Se possível, inclua uma timeline "hora a hora" ou "minuto a minuto" dos eventos críticos durante o teste.

---

## FORMATO DE SAÍDA ESPERADO
Entregue em Markdown com títulos H2/H3, tabelas para comparações, e listas para ações. Não omita nenhuma das 12 seções acima.
```

---

## Como Usar

1. **Copie** o bloco acima (entre as crases triplas).
2. **Cole** no chat da IA (ChatGPT, Gemini, Claude, etc).
3. **Anexe** os dados do teste:
   - Export do k6 (`k6 run --out json=result.json`)
   - CSV de métricas do Datadog (Infrastructure List, Metrics Explorer)
   - JSON de traces do Datadog (APM > Traces > Export)
   - Screenshots de dashboards
   - Logs exportados (`ddlogs` CLI ou arquivo `.txt`/`.json`)
4. **Adicione contexto extra** se necessário: "Teste realizado dia 23/04 às 14h, 500 VUs, duração 30min, rota /api/v1/pagamentos".

---

## Dicas para Melhores Resultados

| Problema | Solução |
|----------|---------|
| IA não tem acesso aos seus arquivos | Cole o conteúdo textual diretamente, ou use a feature de "attach file" se disponível. |
| Muitos dados (limite de contexto) | Foque no período crítico do teste (ex: últimos 15 min), ou divida em 2 prompts: infra + aplicação. |
| Métricas do Datadog em imagem | Use OCR ou copie os valores das tabelas/charts manualmente. |
| IA generaliza demais | Peça: "Cite a métrica exata e o valor numérico que comprova essa afirmação." |

---

## Exemplo de Contexto Adicional (opcional, anexe junto)

```text
CONTEXTO ADICIONAL DO TESTE:
- Data/Hora: 2024-04-23 14:00-14:30 UTC
- Ferramenta: k6
- Rote: POST /api/v1/pagamentos
- Throughput alvo: 1000 RPS (baseline Axway = 980 RPS)
- VUs: 500
- Duração: 30 min
- Kong config: 3 replicas, limits 2CPU/4GB, requests 1CPU/2GB
- Backend: EC2 c5.2xlarge, .NET 6 + Java 17 (mesma instância)
- Plugins ativos: rate-limiting, jwt, datadog (métricas), opentelemetry (traces)
```
