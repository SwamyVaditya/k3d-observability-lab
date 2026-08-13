# Runbook: Checkout SLO Burning

**Alert:** `CheckoutSLOBurning`, `CheckoutErrorBudgetExhausted`
**Severity:** critical (0.5% burn) / page (2% burn)
**SLO:** Checkout error rate < 0.5% over 5m
**Team:** app
**Service:** frontend / checkout / kafka (all in `monitoring` namespace)
**Cluster:** k3d-observability-lab

---

## Summary

Checkout failure rate exceeded SLO. Customers cannot place orders. Orders API returning 500s.

- `CheckoutSLOBurning`: `slo:checkout:error_rate:5m > 0.005` for 2m → 0.5% threshold
- `CheckoutErrorBudgetExhausted`: `slo:checkout:error_rate:5m > 0.02` for 5m → 4x burn, page immediately
- `CheckoutTrafficAbsent`: `slo:checkout:traffic:5m == 0` for 15m → no traffic

In this lab, all demo app components (frontend, checkout, cart, kafka) and observability stack (prometheus, grafana, alertmanager) are in `monitoring` namespace. Argo CD is in `argocd` namespace.

---

## Symptoms

- Slack `#alerts-sre` messages:
  - `:rotating_light: [FIRING] CheckoutSLOBurning (1x) • critical | slo=checkout`
  - `Checkout failure is 99.98% (budget 99.98% used). Current value: 0.999... Check: kubectl -n monitoring get pods | grep kafka`
- Grafana:
  - Dashboard: `SRE > 00 - Master SRE - One Screen` (uid: `master-sre-one`)
  - Panels:
    - `Traffic - req/s` ~ 2-6 req/s (if curl loop running)
    - `Errors - Error % (5m)` > 0.5%
    - `SLO - Burn Rate` > 0.5% line
    - `Business - Orders / min` → 0
    - `Current Errors - checkout 500/s` spiking
- Prometheus:
  - Alerts → `CheckoutSLOBurning` FIRING, Value ~0.99

---

## Impact

- **Business:** Orders/min drops to 0. No revenue.
- **User:** `POST http://shop.local/api/checkout?currencyCode=USD` returns 500.
- **Dependencies:** Cart, Product APIs may still work (33% error rate if only checkout failing).

---

## Diagnosis (in order)

### 1. Confirm alert is real (not stale)

```powershell
# Port-forward Prometheus
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090
# Open http://localhost:9090 and query:
# slo:checkout:error_rate:5m
# sum(rate(app_frontend_requests_total{target=~".*checkout.*"}[5m]))
# sum(rate(app_frontend_requests_total{target=~".*checkout.*",status="500"}[5m]))

# Check Alertmanager status
kubectl -n monitoring get alertmanager
kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager
kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=20
```

### 2. Check demo services (root cause is usually kafka)

```powershell
kubectl -n monitoring get pods | Select-String "kafka|checkout|frontend|cart|load"
kubectl -n monitoring get pods -o wide

# Most common cause: kafka disabled or crashed for chaos test
kubectl -n monitoring logs -l app=checkout --tail=100 | Select-String -Pattern "kafka|KAFKA|broker|timeout|500"
kubectl -n monitoring logs -l app=kafka --tail=100
kubectl -n monitoring describe pod -l app=kafka
kubectl -n monitoring describe pod -l app=checkout

# Check if kafka was scaled to 0
kubectl -n monitoring get deployment kafka
```

### 3. Check traffic source

In this repo, `load-generator.enabled: false` by default. You must generate traffic manually:

```powershell
while ($true) {
  curl.exe -s http://shop.local/api/products > $null
  curl.exe -s http://shop.local/api/cart > $null
  curl.exe -s -X POST "http://shop.local/api/checkout?currencyCode=USD" > $null
  Start-Sleep -Milliseconds 500
}
```

If no loop running → `CheckoutTrafficAbsent` will fire after 15m (expected).

```powershell
kubectl -n monitoring get deployment -l app=load-generator
kubectl -n monitoring logs -l app=load-generator --tail=30
```

### 4. Check dependencies

```powershell
kubectl -n monitoring get pods
kubectl -n monitoring logs -l app=cart --tail=50
kubectl -n monitoring logs -l app=frontend --tail=50
```

---

## Mitigation

### Quick fix - Restore kafka (fixes 90% of cases)

```powershell
# If kafka was scaled to 0 for chaos testing:
kubectl -n monitoring scale deployment kafka --replicas=1
kubectl -n monitoring rollout status deployment/kafka
kubectl -n monitoring rollout restart deployment/checkout
kubectl -n monitoring get pods -w
```

### If checkout pod crashlooping

```powershell
kubectl -n monitoring delete pod -l app=checkout
kubectl -n monitoring rollout restart deployment/checkout
```

### If frontend down

```powershell
kubectl -n monitoring rollout restart deployment/frontend
kubectl -n monitoring rollout restart deployment/frontendproxy
```

### If no traffic (CheckoutTrafficAbsent alert)

Start the manual curl loop (see Diagnosis step 3) or:

```powershell
kubectl -n monitoring rollout restart deployment/load-generator
```

### Verify fix

```powershell
curl.exe -s -X POST "http://shop.local/api/checkout?currencyCode=USD" -i
# Expect 200, not 500

# Watch metrics recover (2-3 minutes)
# Query in Prometheus: sum(rate(app_frontend_requests_total{target=~".*checkout.*",status!~"5.."}[5m])) * 60
# Should go from 0 to >0

# Grafana: SRE > 00 - Master SRE - One Screen
# Business - Orders / min should spike
# Error % should drop < 0.5%
```

Wait for Slack: `:white_check_mark: [RESOLVED] CheckoutSLOBurning`

---

## Known Issues in k3d Lab (all in monitoring namespace)

### Alertmanager not firing to Slack

**Symptoms:** `kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager` shows:
`can't evaluate field Value in type template.Alert` or `notify retry canceled`

**Cause:** Template used `.Value` (Prometheus) instead of `.Annotations.summary` (Alertmanager).

**Fix:** Check `apps/monitoring/prometheus-grafana-values.yaml`:

```yaml
alertmanager:
  enabled: true
  config:
    global:
      resolve_timeout: 5m
      slack_api_url_file: /etc/alertmanager/secrets/alertmanager-slack/slack_api_url
    templates:
      - '/etc/alertmanager/config/*.tmpl'
    route:
      group_by: ['alertname', 'slo', 'severity']
      group_wait: 30s
      group_interval: 2m
      repeat_interval: 4h
      receiver: 'slack-sre'
      routes:
        - receiver: 'null'
          matchers:
            - alertname = "Watchdog"
        - receiver: 'null'
          matchers:
            - alertname =~ "KubeControllerManagerDown|KubeSchedulerDown|KubeProxyDown|AlertmanagerClusterCrashlooping"
    receivers:
      - name: 'null'
      - name: 'slack-sre'
        slack_configs:
          - channel: '#alerts-sre'
            send_resolved: true
            title: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
            text: '{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}'
  alertmanagerSpec:
    secrets:
      - alertmanager-slack
```

Check secret mount path must be: `/etc/alertmanager/secrets/alertmanager-slack/slack_api_url` (not `/etc/alertmanager/secrets/slack_api_url`)

If `kubectl -n monitoring get alertmanager` shows `Reconciled=False` with `undefined receiver "null"`:
- Add dummy receiver `- name: 'null'` to fix Watchdog route
- Delete broken secret: `kubectl -n monitoring delete secret alertmanager-prometheus-stack-kube-prom-alertmanager-generated`
- Force Argo sync: Argo CD UI (argocd namespace) → app `prometheus-stack` → Sync → Force

### KubeControllerManagerDown / KubeProxyDown / KubeSchedulerDown firing in k3d

These are expected false positives in k3d (k3d doesn't run those components as Prometheus targets). Disabled in values:

```yaml
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeProxy:
  enabled: false
etcd:
  enabled: false
```

### AlertmanagerClusterCrashlooping firing after restarts

Expected after `rollout restart` or deleting StatefulSet. Query: `changes(process_start_time_seconds{job="prometheus-stack-kube-prom-alertmanager",namespace="monitoring"}[10m]) > 4`

Will auto-resolve after 10m of stable run. No action needed.

### Dashboard panels showing 0 or No data

- `Traffic - req/s` shows 0: query window `[1m]` too short for low manual curl traffic. Use `[5m]`.
- `Business - Orders / min` shows No data: normal when all checkouts are 500s (0 successful). Use `or vector(0)` to show 0.

See `apps/monitoring/dashboards/08-master-sre.yaml` for fixed queries.

---

## Prevention

- Don't scale kafka to 0 in prod: add PodDisruptionBudget
- Add liveness probe to checkout
- Set `load-generator.enabled: true` for continuous traffic or use synthetic monitoring
- Set `alertmanager.config.route.repeat_interval: 4h` to avoid Slack spam (was 5m)
- Group alerts by `alertname, slo, severity` to avoid 1 message per alert

---

## Dashboards & Links

- Grafana: `http://grafana.local` → Folder `SRE` → `00 - Master SRE - One Screen` (uid: `master-sre-one`)
- Prometheus: `http://prometheus.local` → Alerts → `CheckoutSLOBurning`
- Alertmanager: `kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-alertmanager 9093:9093`
- Argo CD: `http://argocd.local` → namespace `argocd` → app `prometheus-stack`
- Slack: `#alerts-sre` (T0BNY6DFKAT / C0BPFUPHYGZ)
- Otel Demo Shop: `http://shop.local`

---

## Recording Rules Reference

Located in `apps/monitoring/prometheus-rules/otel-demo-slos.yaml` (or `monitoring/otel-demo-slos-...` ConfigMap):

```yaml
- record: slo:checkout:error_rate:5m
  expr: |
    sum(rate(app_frontend_requests_total{target="/api/checkout",status="500"}[5m]))
    /
    (sum(rate(app_frontend_requests_total{target="/api/checkout"}[5m])) + 0.0001)

- record: slo:checkout:traffic:5m
  expr: sum(rate(app_frontend_requests_total{target="/api/checkout"}[5m]))

- record: slo:checkout:budget_remaining_percent
  expr: 100 * (1 - slo:checkout:error_rate:5m)
```

Alerts:

```yaml
- alert: CheckoutSLOBurning
  expr: slo:checkout:error_rate:5m > 0.005
  for: 2m
  labels: { severity: critical, slo: checkout, team: app }
  
- alert: CheckoutErrorBudgetExhausted
  expr: slo:checkout:error_rate:5m > 0.02
  for: 5m
  labels: { severity: page, slo: checkout, team: app }
```

---

## Escalation

If not resolved in 15 minutes:

1. Check Argo CD: `kubectl -n argocd get applications` → `prometheus-stack` sync status
2. Check monitoring stack: `kubectl -n monitoring get all | Select-String "prometheus|alertmanager|grafana"`
3. Check operator: `kubectl -n monitoring get pods | Select-String "operator"`
4. Page app team lead (team=app label)
5. Open incident channel with Slack alert link

---

## Repo Structure for this Lab

```
k3d-observability-lab/
├── .github/
│   └── workflows/
│       └── ci.yaml
├── apps/
│   └── monitoring/
│       ├── dashboards/
│       │   ├── 01-infra-cluster.yaml
│       │   ├── 02-infra-k8s-use.yaml
│       │   ├── 03-app-red.yaml
│       │   ├── 04-app-business.yaml
│       │   ├── 05-logs.yaml
│       │   ├── 06-traces.yaml
│       │   ├── 08-master-sre.yaml
│       │   └── test-dashboard.yaml
│       ├── slos/
│       │   ├── dashboard.yaml
│       │   └── rules.yaml
│       ├── alloy-app.yaml
│       ├── alloy-values.yaml
│       ├── dashboards-app.yaml
│       ├── ingress.yaml
│       ├── loki-app.yaml
│       ├── loki-values.yaml
│       ├── minio-app.yaml
│       ├── minio-sealed-secret.yaml
│       ├── minio-values.yaml
│       ├── otel-demo-app.yaml
│       ├── otel-demo-values.yaml
│       ├── prometheus-app.yaml
│       ├── prometheus-grafana-values.yaml
│       ├── sealed-alertmanager-slack.yaml
│       ├── tempo-app.yaml
│       └── tempo-values.yaml
├── argocd/
│   └── root-app.yaml
├── bootstrap/
│   ├── argocd-install.yaml
│   └── main.tf
├── clusters/
│   └── observability-cluster.yaml
├── docs/
│   └── runbooks/
│       └── checkout-slo-burning.md
├── .gitignore
└── README.md
```

All workloads in `monitoring` namespace (k3d lab simplification). No `otel-demo` namespace exists.
