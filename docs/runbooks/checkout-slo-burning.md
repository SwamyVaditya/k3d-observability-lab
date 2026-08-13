# Runbook: Checkout SLO Burning

**Alert:** `CheckoutSLOBurning`, `CheckoutErrorBudgetExhausted`
**Severity:** critical (0.5% burn) / page (2% burn)
**SLO:** Checkout error rate < 0.5% over 5m
**Team:** app
**Service:** otel-demo frontend / checkout / kafka

---

## Summary

Checkout failure rate exceeded SLO. Customers cannot place orders. Orders API returning 500s.

- `CheckoutSLOBurning`: `slo:checkout:error_rate:5m > 0.005` for 2m → 0.5% threshold
- `CheckoutErrorBudgetExhausted`: `slo:checkout:error_rate:5m > 0.02` for 5m → 4x burn, page immediately

Error budget remaining is tracked in Grafana dashboard `00 - Master SRE - One Screen`.

---

## Symptoms

- Slack `#alerts-sre` messages:
  - `:rotating_light: [FIRING] CheckoutSLOBurning (1x) • critical | slo=checkout`
  - `Checkout failure is 99.98% (budget 99.98% used). Current value: 0.999... Check: kubectl -n otel-demo get pods | grep kafka`
- Grafana:
  - Dashboard: `SRE > 00 - Master SRE - One Screen`
  - Panels:
    - `Traffic - req/s` ~ 2-6 req/s (if load running)
    - `Errors - Error % (5m)` > 0.5%
    - `SLO - Burn Rate` > 0.5% line
    - `Business - Orders / min` → 0
    - `Current Errors - checkout 500/s` spiking
- Prometheus:
  - `http://prometheus.local` → Alerts → `CheckoutSLOBurning` FIRING, Value ~0.99

---

## Impact

- **Business:** Orders/min drops to 0. No revenue.
- **User:** `POST http://shop.local/api/checkout?currencyCode=USD` returns 500.
- **Dependencies:** Cart, Product APIs may still work (33% error rate if only checkout failing).

---

## Diagnosis (in order)

### 1. Confirm alert is real (not stale)

```powershell
# Check Prometheus recording rules
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090
# Open http://localhost:9090 and query:
# slo:checkout:error_rate:5m
# sum(rate(app_frontend_requests_total{target=~".*checkout.*"}[5m]))
# sum(rate(app_frontend_requests_total{target=~".*checkout.*",status="500"}[5m]))

# Check Alertmanager
kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager
kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=20
```

### 2. Check otel-demo services (root cause is usually kafka)

```powershell
kubectl -n otel-demo get pods | Select-String "kafka|checkout|frontend|cart"
kubectl -n otel-demo get pods -o wide

# Most common cause: kafka disabled or crashed
kubectl -n otel-demo logs -l app=checkout --tail=100 | Select-String -Pattern "kafka|KAFKA|broker|timeout|500"
kubectl -n otel-demo logs -l app=kafka --tail=100
kubectl -n otel-demo describe pod -l app=kafka
kubectl -n otel-demo describe pod -l app=checkout
```

### 3. Check traffic source

```powershell
# If load-generator is disabled (as in this lab), you must generate traffic manually:
# while ($true) {
#   curl.exe -s http://shop.local/api/products > $null
#   curl.exe -s http://shop.local/api/cart > $null
#   curl.exe -s -X POST "http://shop.local/api/checkout?currencyCode=USD" > $null
#   Start-Sleep -Milliseconds 500
# }

kubectl -n otel-demo get deployment load-generator
kubectl -n otel-demo logs -l app=load-generator --tail=30
```

### 4. Check dependencies (DB, Redis, etc.)

```powershell
kubectl -n otel-demo get pods
kubectl -n otel-demo logs -l app=cart --tail=50
kubectl -n otel-demo logs -l app=frontend --tail=50
```

---

## Mitigation

### Quick fix - Restore kafka (fixes 90% of cases)

```powershell
# If kafka was scaled to 0 for chaos testing:
kubectl -n otel-demo scale deployment kafka --replicas=1
kubectl -n otel-demo rollout status deployment/kafka
kubectl -n otel-demo rollout restart deployment/checkout
kubectl -n otel-demo get pods -w
```

### If checkout pod crashlooping

```powershell
kubectl -n otel-demo delete pod -l app=checkout
kubectl -n otel-demo rollout restart deployment/checkout
```

### If frontend down

```powershell
kubectl -n otel-demo rollout restart deployment/frontend
kubectl -n otel-demo rollout restart deployment/frontendproxy
```

### If no traffic (CheckoutTrafficAbsent alert)

```powershell
kubectl -n otel-demo rollout restart deployment/load-generator
# OR start manual curl loop (see Diagnosis step 3)
```

### Verify fix

```powershell
curl.exe -s -X POST "http://shop.local/api/checkout?currencyCode=USD" -i
# Expect 200, not 500

# Watch metrics recover (2-3 minutes)
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090
# Query: sum(rate(app_frontend_requests_total{target=~".*checkout.*",status!~"5.."}[5m])) * 60
# Should go from 0 to >0

# Grafana: SRE > 00 - Master SRE - One Screen
# Business - Orders / min should spike
# Error % should drop < 0.5%
```

Wait for Slack: `:white_check_mark: [RESOLVED] CheckoutSLOBurning`

---

## Known Issues in k3d Lab

### Alertmanager not firing to Slack

**Symptoms:** `kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager` shows:
`can't evaluate field Value in type template.Alert`

**Cause:** Template used `.Value` (Prometheus) instead of `.Annotations.summary` (Alertmanager).

**Fix:** Check `apps/monitoring/prometheus-grafana-values.yaml`:

```yaml
alertmanager:
  config:
    route:
      group_by: ['alertname']
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
```

Also check secret mount path must be: `/etc/alertmanager/secrets/alertmanager-slack/slack_api_url`

If `kubectl -n monitoring get alertmanager` shows `Reconciled=False` with `undefined receiver "null"`:
- Add dummy receiver `- name: 'null'` to fix Watchdog route
- Delete broken secret: `kubectl -n monitoring delete secret alertmanager-prometheus-stack-kube-prom-alertmanager-generated`

### KubeControllerManagerDown / KubeProxyDown / KubeSchedulerDown firing in k3d

These are expected false positives in k3d. Disabled in values:

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

Expected after `rollout restart`. Will auto-resolve after 10m of stable run. No action needed, or route to null.

### Dashboard panels showing 0 or No data

- `Traffic - req/s` shows 0: query window `[1m]` too short for low traffic. Use `[5m]`.
- `Business - Orders / min` shows No data: normal when all checkouts are 500s (0 successful). Add `or vector(0)` to show 0 instead.

See `apps/monitoring/dashboards/08-master-sre.yaml` for fixed queries.

---

## Prevention

- Don't scale kafka to 0 in prod: add PDB
- Add liveness probe to checkout
- Set `load-generator.enabled: true` for continuous traffic or use synthetic monitoring
- Set `alertmanager.config.route.repeat_interval: 4h` to avoid Slack spam (was 5m)

---

## Dashboards & Links

- Grafana: `http://grafana.local` → Folder `SRE` → `00 - Master SRE - One Screen` (uid: `master-sre-one`)
- Prometheus: `http://prometheus.local` → Alerts
- Alertmanager: `http://alertmanager.local` or `kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-alertmanager 9093:9093`
- Argo CD: `http://argocd.local` → app `prometheus-stack` (namespace: `argocd`)
- Slack: `#alerts-sre` (T0BNY6DFKAT / C0BPFUPHYGZ)
- Otel Demo Shop: `http://shop.local`

---

## Recording Rules Reference

Located in `apps/monitoring/prometheus-rules/otel-demo-slos.yaml`:

```yaml
- record: slo:checkout:error_rate:5m
  expr: |
    sum(rate(app_frontend_requests_total{target="/api/checkout",status="500"}[5m]))
    /
    (sum(rate(app_frontend_requests_total{target="/api/checkout"}[5m])) + 0.0001)

- record: slo:checkout:budget_remaining_percent
  expr: |
    100 * (1 - slo:checkout:error_rate:5m)
```

---

## Escalation

If not resolved in 15 minutes:

1. Check Argo CD: `argocd` namespace → `prometheus-stack` app sync status
2. Check monitoring stack: `kubectl -n monitoring get all`
3. Page app team lead (team=app label)
4. Open incident channel with Slack alert link
