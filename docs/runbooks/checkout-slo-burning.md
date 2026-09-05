# Runbook: Checkout SLO Burning

**Alert:** `CheckoutSLOBurning` (2x burn), `CheckoutSLOFastBurn` (10x burn) | 
**Severity:** warning (2x) / critical (10x) | 
**SLO:** Checkout 99.5% availability. Allowed error budget = 0.5% (0.005)
**Team:** app | 
**Service:** frontend / checkout / kafka (all in `monitoring` namespace) | 
**Cluster:** k3d-observability-lab

---

## Summary

Checkout failure rate is burning error budget faster than allowed.

Burn rate definition (Google SRE Workbook):
```
burn_rate = observed_error_rate / allowed_error_rate
allowed_error_rate = 0.005 (0.5% for 99.5% SLO)
1x burn = 0.5% errors (exactly at budget)
2x burn = 1.0% errors (SLOBurning)
10x burn = 5.0% errors (FastBurn)
```

Customers cannot place orders when burning. Orders API returning 500s.

- `CheckoutSLOBurning`: `slo:checkout:burn_rate:5m > 2 AND burn_rate:1h > 2` for 2m → multi-window, avoids flapping
- `CheckoutSLOFastBurn`: `slo:checkout:burn_rate:5m > 10` for 2m → ~5% errors, page immediately
- `CheckoutTrafficAbsent`: `slo:checkout:traffic:5m == 0` for 15m → no traffic (manual load-gen needed in this lab)

All workloads in `monitoring` namespace (k3d simplification). Argo CD is in `argocd` namespace.

---

## Symptoms

- Slack `#alerts-sre` messages:
  - `:rotating_light: [FIRING] CheckoutSLOBurning - burning at 4.2x`
  - `:rotating_light: [FIRING] CheckoutSLOFastBurn - burning at 120x` (when kafka down, error_rate ~100%)

- Grafana: Dashboard `SRE > 00 - Master SRE - One Screen` (uid: `master-sre-one`)
  - Panels:
    - `Traffic - req/s` ~ 2-6 req/s (if curl loop running)
    - `SLO - True Burn Rate (checkout)` > 2x line
    - `Success % 5m` drops < 99.5%
    - `Business - Orders / min` → 0
    - `Current Errors - checkout 500/s` spiking

- Prometheus: Alerts → `CheckoutSLOBurning` FIRING, Value = burn multiplier e.g. 4.0

---

## Impact

- **Business:** Orders/min drops to 0. At 2x burn, 28d budget exhausts in 14d. At 10x burn, in 2.8d.
- **User:** `POST http://shop.local/api/checkout?currencyCode=USD` returns 500.
- **Dependencies:** Cart, Product APIs may still work (33% error rate if only checkout failing).

---

## Diagnosis (in order)

### 1. Confirm burn rate is real (not stale)

```
# Port-forward Prometheus
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090

# Open http://localhost:9090 and query:
slo:checkout:error_rate:5m
slo:checkout:error_rate:1h
slo:checkout:burn_rate:5m
slo:checkout:burn_rate:1h
slo:checkout:success_percent:5m
slo:checkout:traffic:5m

# Expected: error_rate:5m=0.02 (2%) => burn_rate:5m=4x
# Check Alertmanager status
kubectl -n monitoring get alertmanager
kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager
kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=20
```

### 2. Check demo services (root cause is usually kafka)

```
kubectl -n monitoring get pods | Select-String "kafka|checkout|frontend|cart|load"
kubectl -n monitoring get pods -o wide
kubectl -n monitoring logs -l app=checkout --tail=100 | Select-String -Pattern "kafka|KAFKA|broker|timeout|500"
kubectl -n monitoring logs -l app=kafka --tail=100
kubectl -n monitoring describe pod -l app=kafka
kubectl -n monitoring describe pod -l app=checkout
kubectl -n monitoring get deployment kafka
```

### 3. Check traffic source

In this repo, `load-generator.enabled: false` by default. You must generate traffic manually:

```
while ($true) {
  curl.exe -s http://shop.local/api/products > $null
  curl.exe -s http://shop.local/api/cart > $null
  curl.exe -s -X POST "http://shop.local/api/checkout?currencyCode=USD" > $null
  Start-Sleep -Milliseconds 500
}
```

If no loop running → `CheckoutTrafficAbsent` will fire after 15m (expected).

```
kubectl -n monitoring get deployment -l app=load-generator
kubectl -n monitoring logs -l app=load-generator --tail=30
```

### 4. Check dependencies

```
kubectl -n monitoring get pods
kubectl -n monitoring logs -l app=cart --tail=50
kubectl -n monitoring logs -l app=frontend --tail=50
```

---

## Mitigation

### Quick fix - Restore kafka (fixes 90% of cases)

```
# If kafka was scaled to 0 for chaos testing:
kubectl -n monitoring scale deployment kafka --replicas=1
kubectl -n monitoring rollout status deployment/kafka
kubectl -n monitoring rollout restart deployment/checkout
kubectl -n monitoring get pods -w
```

### If checkout pod crashlooping

```
kubectl -n monitoring delete pod -l app=checkout
kubectl -n monitoring rollout restart deployment/checkout
```

### If frontend down

```
kubectl -n monitoring rollout restart deployment/frontend
kubectl -n monitoring rollout restart deployment/frontendproxy
```

### If no traffic (CheckoutTrafficAbsent alert)

Start the manual curl loop (see Diagnosis step 3) or:

```
kubectl -n monitoring rollout restart deployment/load-generator
```

### Verify fix - burn should drop <1x

```
curl.exe -s -X POST "http://shop.local/api/checkout?currencyCode=USD" -i
# Expect 200, not 500

# Watch metrics recover (2-3 minutes)
# In Prometheus:
# slo:checkout:burn_rate:5m < 1
# slo:checkout:success_percent:5m > 99.5
# sum(rate(app_frontend_requests_total{target=~".*checkout.*",status!~"5.."})) * 60 > 0

# Grafana: SRE > 00 - Master SRE - One Screen
# Business - Orders / min should spike
# Success % should rise > 99.5%
```

Wait for Slack: `:white_check_mark: [RESOLVED] CheckoutSLOBurning`

---

## Why not full error-budget accounting?

Full SLO implementation needs 28d window with long-term storage (Thanos/Cortex/Mimir).

In k3d lab with local Prometheus (hours retention), we approximate with true burn-rate.

- `slo:checkout:success_percent:5m` = current success % in 5m window, NOT remaining budget over 28d.
- `slo:checkout:burn_rate:5m` = `error_rate:5m / 0.005` = how fast we are burning.
- `budget_remaining_percent` is kept as deprecated alias for dashboard compat.

This is acceptable for portfolio if documented (this runbook).

Production mapping: Thanos + recording rules over 1h/6h/1d/28d + budget burn-down dashboard + multi-window multi-burn-rate alerts (1h/5m/6h).

---

## Known Issues in k3d Lab (all in monitoring namespace)

### Alertmanager not firing to Slack

**Symptoms:** `kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager` shows: `can't evaluate field Value in type template.Alert` or `notify retry canceled`

**Cause:** Template used `.Value` (Prometheus) instead of `.Annotations.summary` (Alertmanager).

**Fix:** Check `apps/monitoring/prometheus-grafana-values.yaml`:

```
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
            title: '[{{.Status | toUpper }}] {{.GroupLabels.alertname }}'
            text: '{{ range.Alerts }}{{.Annotations.summary }}{{ end }}'
```

Check secret mount path must be: `/etc/alertmanager/secrets/alertmanager-slack/slack_api_url`

If `kubectl -n monitoring get alertmanager` shows `Reconciled=False` with `undefined receiver "null"`:
- Add dummy receiver `- name: 'null'` to fix Watchdog route
- Delete broken secret: `kubectl -n monitoring delete secret alertmanager-prometheus-stack-kube-prom-alertmanager-generated`
- Force Argo sync: Argo CD UI (argocd namespace) → app `prometheus-stack` → Sync → Force

### KubeControllerManagerDown / KubeProxyDown / KubeSchedulerDown firing in k3d

These are expected false positives in k3d. Disabled in values:

```
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

Expected after `rollout restart` or deleting StatefulSet. Query: `changes(process_start_time_seconds{job="prometheus-stack-kube-prom-alertmanager",namespace="monitoring"}) > 4`

Will auto-resolve after 10m of stable run. No action needed.

### Dashboard panels showing 0 or No data

- `Traffic - req/s` shows 0: query window `` too short for low manual curl traffic. Use ``.
- `Business - Orders / min` shows No data: normal when all checkouts are 500s (0 successful). Use `or vector(0)` to show 0.
- See `apps/monitoring/dashboards/08-master-sre.yaml` for fixed queries.

---

## Prevention

- Don't scale kafka to 0 in prod: add PodDisruptionBudget
- Add liveness probe to checkout
- Set `load-generator.enabled: true` for continuous traffic or use synthetic monitoring
- Set `alertmanager.config.route.repeat_interval: 4h` to avoid Slack spam (was 5m)
- Group alerts by `alertname, slo, severity` to avoid 1 message per alert
- Use multi-window burn-rate (5m + 1h) to avoid flapping on sparse traffic

---

## Dashboards & Links

- Grafana: `http://grafana.local` → Folder `SRE` → `00 - Master SRE - One Screen` (uid: `master-sre-one`)
- Prometheus: `http://prometheus.local` → Alerts → `CheckoutSLOBurning`
- Alertmanager: `kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-alertmanager 9093:9093`
- Argo CD: `http://argocd.local` → namespace `argocd` → app `prometheus-stack`
- Slack: `#alerts-sre`
- Otel Demo Shop: `http://shop.local`

---

## Recording Rules Reference - TRUE burn rate

Located in `apps/monitoring/slos/rules.yaml`:

```
- record: slo:checkout:error_rate:5m
  expr: sum(rate(app_frontend_requests_total{target="/api/checkout",status="500"})) / (sum(rate(...))+0.0001)

- record: slo:checkout:error_rate:1h
  expr: sum(rate(...)) / (sum(rate(...))+0.0001)

- record: slo:checkout:slo_target
  expr: "vector(0.995)"

- record: slo:checkout:error_budget
  expr: "vector(0.005)"

- record: slo:checkout:burn_rate:5m
  expr: slo:checkout:error_rate:5m / 0.005

- record: slo:checkout:burn_rate:1h
  expr: slo:checkout:error_rate:1h / 0.005

- record: slo:checkout:success_percent:5m
  expr: 100 * (1 - slo:checkout:error_rate:5m)

- record: slo:checkout:traffic:5m
  expr: sum(rate(app_frontend_requests_total{target="/api/checkout"}))
```

Alerts:

```
- alert: CheckoutSLOBurning
  expr: slo:checkout:burn_rate:5m > 2 and slo:checkout:burn_rate:1h > 2
  for: 2m
  labels: { severity: warning, slo: checkout }

- alert: CheckoutSLOFastBurn
  expr: slo:checkout:burn_rate:5m > 10
  for: 2m
  labels: { severity: critical, slo: checkout }
```

Multi-window pattern prevents flapping on low traffic.

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
│   ├── monitoring/
│   │   ├── dashboards/
│   │   │   ├── 01-infra-cluster.yaml
│   │   │   ├── 02-infra-k8s-use.yaml
│   │   │   ├── 03-app-red.yaml
│   │   │   ├── 04-app-business.yaml
│   │   │   ├── 05-logs.yaml
│   │   │   ├── 06-traces.yaml
│   │   │   ├── 08-master-sre.yaml
│   │   │   └── test-dashboard.yaml
│   │   ├── slos/
│   │   │   ├── dashboard.yaml
│   │   │   └── rules.yaml
│   │   ├── alloy-app.yaml
│   │   ├── alloy-values.yaml
│   │   ├── dashboards-app.yaml
│   │   ├── hardening-app.yaml
│   │   ├── ingress.yaml
│   │   ├── loki-app.yaml
│   │   ├── loki-values.yaml
│   │   ├── minio-app.yaml
│   │   ├── minio-sealed-secret.yaml
│   │   ├── minio-values.yaml
│   │   ├── otel-demo-app.yaml
│   │   ├── otel-demo-values.yaml
│   │   ├── prometheus-app.yaml
│   │   ├── prometheus-grafana-values.yaml
│   │   ├── sealed-alertmanager-slack.yaml
│   │   ├── tempo-app.yaml
│   │   └── tempo-values.yaml
│   └── platform/
│       └── hardening/
│           ├── 02-poddisruptionbudgets.yaml
│           └── README.md
├── argocd/
│   ├── projects/
│   │   └── observability-project.yaml
│   └── root-app.yaml
├── bootstrap/
│   └── main.tf
├── clusters/
│   └── observability-cluster.yaml
├── docs/
│   ├── images/
│   │   ├── diagram1_dark.png
│   │   ├── diagram1_light.png
│   │   ├── diagram2_dark_new.png
│   │   ├── diagram2_dark.png
│   │   ├── diagram2_light_new.png
│   │   └── diagram2_light.png
│   ├── runbooks/
│   │   └── checkout-slo-burning.md
│   ├── architecture.md
│   ├── demo-self-heal.gif
│   ├── failure-scenarios.md
│   └── key-decisions.md
├── scripts/
│   └── demo-self-heal.sh
├── .gitattributes
├── .gitignore
├── alertmanager-slack-example.yaml
├── HARDENING.md
├── minio-secret-example.yaml
└── README.md

```

All workloads in `monitoring` namespace (k3d lab simplification). No `otel-demo` namespace exists.
```

