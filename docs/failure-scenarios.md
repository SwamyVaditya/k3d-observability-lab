# Failure Scenarios / SRE Exercises

Hands-on SRE exercises for the k3d-observability-lab. Each scenario maps to a real production incident pattern and uses your LGTM stack + GitOps flow.

> Prerequisites: `k3d cluster list`, `kubectl -n argocd get apps`, Grafana at `grafana.local`, Argo CD at `argocd.local`

## Scenario 1 — Checkout error rate increases (SLO burn)

**Goal:** Practice SLO-based alerting → trace correlation → log inspection → runbook execution.

**Steps:**
1. **Trigger failure:** Edit `apps/monitoring/otel-demo.values.yaml`: set `OTEL_DEMO_CART_FAILURE_RATE=0.3`, push to Git
2. **Alert fires:** Grafana → Prometheus → `sum(rate(http_requests_total{service="checkout", status="500"}))` → `firing: CheckoutSLOBurning`
3. **Investigate metrics:** Grafana Dashboard Checkout panel → `checkout_failure_ratio` spike
4. **Correlate traces:** Grafana → Tempo → Service `checkout` → Find trace with error → span `kafka` latency 2.5s
5. **Inspect logs:** Loki → `{service="checkout"} |= "error"` → `KafkaTimeoutException`
6. **Identify failing component:** cart → kafka (from Diagram 2)
7. **Follow runbook:** Open `docs/runbooks/checkout-slo-burning.md`
8. **Recover:** `git revert HEAD && git push` → Argo syncs in 30s

**Artifact:** Screenshot of Tempo trace linked to Loki log via traceID + Slack alert with `runbook_url`.

## Scenario 2 — Pod becomes unhealthy (Readiness probe)

**Steps:**
1. Inject: `kubectl -n otel-demo set env deployment/frontend OTEL_DEMO_UNHEALTHY=true`
2. Readiness fails: `kubectl describe pod` → probe failed 500, endpoint removed `kubectl get endpoints frontend`
3. Alert: `KubePodNotReady`
4. Diagnosis: `kubectl logs --previous`, Loki `{app="frontend"} |= "health check failed"`
5. Recovery: Remove env → pod ready → endpoint re-added

**Lesson:** Readiness removes bad pod from LB without restart.

## Scenario 3 — Node disruption (PDB protects)

**Setup:** `apps/monitoring/hardening-app.yaml` → `02-poddisruptionbudgets.yaml` has `minAvailable: 1` for cart/checkout/frontend/kafka

**Steps:**
1. Observe: `kubectl get pods -o wide` → note cart node
2. Cordon: `kubectl cordon k3d-observability-lab-agent-0`
3. Drain: `kubectl drain ... --ignore-daemonsets` → blocks when only 1 cart left, `kubectl get pdb` shows `ALLOWED DISRUPTIONS 0`
4. Validate: `shop.local` still works, Grafana `kube_poddisruptionbudget_status_current_healthy` >=1
5. Uncordon: `kubectl uncordon ...`
6. Without PDB: Delete PDB → drain kills all cart → checkout fails

## Scenario 4 — GitOps drift (Manual → Self-heal)

**Steps:**
1. Baseline: `kubectl get deployment cart -o yaml | grep replicas` → 1
2. Manually change: `kubectl scale deployment cart --replicas=5`
3. Argo detects: UI → OutOfSync → Diff `replicas: 1 → 5`
4. Self-heal: Argo SYNC or wait 3m → back to 1
5. Audit: `argocd app history`

**Lesson:** Prevents drift critical for 50 microservices.

## Scenario 5 — Configuration deployment (Git → CI → Argo)

**Steps:**
1. Change Git: `frontend.replicaCount: 2` in `apps/monitoring/otel-demo.values.yaml`
2. GitHub Actions: `ci.yaml` → terraform fmt, helm lint, kubeval, Kyverno check - must be green
3. Argo syncs: `argocd app get otel-demo` → OutOfSync → SYNC → `kubectl get deployment frontend` → 2
4. Verify: `shop.local` 2 pods, Prometheus no alerts
5. Rollback: `git revert && git push`

## Scenario 6 — Secret Rotation (Your actual bug)

**Steps:**
1. Rotate: `echo -n "newpassword" | kubectl create secret generic minio-creds ... | kubeseal ... > apps/monitoring/minio-sealed-secret.yaml`
2. Push + sync: Argo syncs → MinIO restarts
3. Verify Loki/Tempo still write: Loki `{job="loki"} |= "s3"` no auth errors

## Scenario 7 — Resource Exhaustion (Limits)

**Steps:**
1. Remove limits: `kubectl set resources deployment/cart --limits=...`
2. Inject leak: `stress --vm 1 --vm-bytes 500M`
3. Observe: `kubectl top node` spike, eviction possible
4. Re-apply: `kubectl set resources --limits=cpu=500m,memory=512Mi` or via Git + Kyverno `require-limits.yaml`
5. Validate: Leak OOMKilled, not node

---
