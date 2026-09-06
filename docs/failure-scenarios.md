## Failure Scenarios / SRE Exercises

Hands-on SRE exercises for the k3d-observability-lab. Each scenario maps to a real production incident pattern and uses your LGTM stack + GitOps flow.

> Prerequisites: `k3d cluster list`, `kubectl -n argocd get apps`, Grafana at `grafana.local`, Argo CD at `argocd.local`
> Tested shell: PowerShell 7 + WSL2 Ubuntu. All workloads in `monitoring` namespace (k3d lab simplification). No `otel-demo` namespace exists.
> Reproducibility: Yes, from Git. `terraform -chdir=bootstrap apply` → Argo Root App → 8 apps. Docker volumes survive `k3d cluster delete`; full clean: `k3d cluster delete --all && docker volume prune -f` (documented persistent-data semantics).

## Scenario 1 — Checkout error rate increases (SLO burn - true burn-rate)

**Goal:** Practice SLO burn-rate alerting → trace correlation → log inspection → runbook execution.

**SLO Definition (v1.0 fixed):**
```
allowed_error_rate = 0.005 (0.5% for 99.5% SLO)
burn_rate = error_rate / 0.005
2x burn = 1% errors (CheckoutSLOBurning)
10x burn = 5% errors (CheckoutSLOFastBurn)
slo:checkout:burn_rate:5m = slo:checkout:error_rate:5m / 0.005
slo:checkout:success_percent:5m = 100 * (1 - error_rate:5m)
```

**Steps:**

1. **Trigger failure:** `kubectl -n monitoring scale deployment kafka --replicas=0` (root cause 90% of cases) OR Edit `apps/monitoring/otel-demo-values.yaml`: set failure env, push to Git
2. **Alert fires:** Prometheus `slo:checkout:burn_rate:5m > 2 and burn_rate:1h > 2` for 2m → `CheckoutSLOBurning`. At 100% error rate, burn = 200x → `CheckoutSLOFastBurn` (10x threshold)
3. **Investigate metrics:** Grafana `SRE > 00 - Master SRE - One Screen` → Panel `SLO - True Burn Rate (checkout)` >2x, `Success % 5m` <99.5%
4. **Correlate traces:** Grafana → Tempo → Service `checkout` → Find trace with error → span `kafka` timeout
5. **Inspect logs:** Loki → `{app="checkout"} |= "kafka|timeout|500"` → `KafkaTimeoutException`
6. **Follow runbook:** Open `docs/runbooks/checkout-slo-burning.md` (path corrected: `apps/monitoring/slos/rules.yaml` is source of truth)
7. **Recover:** `kubectl -n monitoring scale deployment kafka --replicas=1 && kubectl -n monitoring rollout restart deployment/checkout` OR `git revert HEAD && git push` → Argo syncs in 30s
8. **Verify:** `slo:checkout:burn_rate:5m <1` and `success_percent:5m >99.5`

**Artifact:** Slack `#alerts-sre` firing with burn multiplier + Grafana burn-rate graph.

## Scenario 2 — Pod becomes unhealthy (Readiness probe)

**Steps:**

1. Inject: `kubectl -n monitoring set env deployment/frontend OTEL_DEMO_UNHEALTHY=true`
2. Readiness fails: `kubectl -n monitoring describe pod -l app=frontend` → probe failed, endpoint removed `kubectl -n monitoring get endpoints frontend`
3. Alert: `KubePodNotReady`
4. Diagnosis: `kubectl -n monitoring logs --previous -l app=frontend`, Loki `{app="frontend"} |= "health check failed"`
5. Recovery: `kubectl -n monitoring set env deployment/frontend OTEL_DEMO_UNHEALTHY-` → pod ready → endpoint re-added

**Lesson:** Readiness removes bad pod from LB without restart. Probes inherited from upstream chart (CI-validated via `helm template`, not overridden).

## Scenario 3 — Node disruption (PDB minAvailable:1 protects voluntary disruption only)

**Setup:** `apps/platform/hardening/02-poddisruptionbudgets.yaml` has `minAvailable: 1` for cart/checkout/frontend/kafka in `monitoring` namespace.

**What PDB guarantees:** Protects against *voluntary* disruption (`kubectl drain`, cluster autoscaler, node upgrade). Blocks eviction when it would leave 0 healthy. Does NOT protect against *involuntary* (node crash, OOMKill, app failure). Does NOT provide HA (HA needs replicas>=2 + topologySpread). This lab intentionally runs 1 replica to stay light; minAvailable:1 prevents taking last replica away.

**Steps:**

1. Observe: `kubectl -n monitoring get pods -o wide` → note cart node
2. Cordon: `kubectl cordon k3d-observability-lab-agent-0`
3. Drain: `kubectl drain k3d-observability-lab-agent-0 --ignore-daemonsets --delete-emptydir-data` → blocks when only 1 cart left, `kubectl -n monitoring get pdb` shows `ALLOWED DISRUPTIONS 0`
4. Validate: `http://shop.local` still works, Grafana `kube_poddisruptionbudget_status_current_healthy` >=1
5. Uncordon: `kubectl uncordon k3d-observability-lab-agent-0`
6. Without PDB: Delete PDB → drain kills all cart → checkout fails

**Interview line:** "PDB protects voluntary disruption, not application failure or node failure."

## Scenario 4 — GitOps drift (Manual → Self-heal) - Live Evidence 2026-09-04

**Goal:** Prove Git is source of truth. `syncPolicy: automated: prune:true, selfHeal:true` on all 8 apps.

**Steps:**

1. Baseline: `kubectl -n monitoring get deploy cart -o yaml | grep replicas` → 1
2. Drift: `kubectl -n monitoring scale deploy cart --replicas=0` (or 5)
3. Detect: Argo CD UI → `otel-demo` → OutOfSync → Diff `replicas: 1 → 0`
4. **Measured self-heal:** `bash scripts/demo-self-heal.sh`

```
=== D1 Self-Healing Demo: monitoring/cart ===
attempt 1: spec.replicas=0 ready=0
attempt 2: spec.replicas=1 ready=1
✅ Self-healed! ArgoCD restored replicas=1 in <60s
```

5. Audit: `kubectl -n argocd get application otel-demo -o yaml | grep -A2 selfHeal` → `selfHeal: true`
6. If k3d cluster manually deleted: `k3d cluster delete observability-cluster --all` → TF state stale → `terraform -chdir=bootstrap apply -replace=null_resource.k3d_cluster -auto-approve` (null_resource limitation documented in `docs/key-decisions.md` - local state intentional, EKS uses S3 backend)

**Lesson:** Even manual `kubectl scale --replicas=0` converges back without human fix. Critical for 50 microservices. Evidence in `HARDENING.md` Section 2.

## Scenario 5 — Configuration deployment (Git → CI → Argo)

**Steps:**

1. Change Git: `frontend.resources.limits.memory: 400Mi` in `apps/monitoring/otel-demo-values.yaml` (resource limits declaratively defined here, not via `kubectl set resources`)
2. GitHub Actions: `ci.yaml` → `terraform fmt`, `helm lint`, `kubeval`, Kyverno check - must be green
3. Argo syncs: `kubectl -n argocd get app otel-demo` → OutOfSync → SYNC → `kubectl -n monitoring get deployment frontend -o jsonpath='{.spec.template.spec.containers[0].resources}'`
4. Verify: `shop.local` works, Prometheus no alerts
5. Rollback: `git revert && git push`

**Interview line for Q1:** "Resource limits are declaratively defined in `otel-demo-values.yaml` per service (cart 50m/64Mi→200m/160Mi) and enforced via Kyverno in prod. `kubectl set resources` is validation only."

## Scenario 6 — Secret Rotation (SealedSecrets)

**Steps:**

1. Rotate: `echo -n "newpassword" | kubectl create secret generic minio-credentials --from-literal=rootPassword=newpassword --dry-run=client -o yaml | kubeseal --format=yaml --controller-name sealed-secrets --controller-namespace kube-system -w apps/monitoring/minio-sealed-secret.yaml`
2. Push + sync: Argo syncs → MinIO restarts (sync-wave 1 before Loki wave 2)
3. Verify Loki/Tempo still write: Loki query `{namespace="monitoring"} |= "s3"` no auth errors, Grafana Explore logs still flowing

## Scenario 7 — Resource Exhaustion (Limits prevent noisy neighbor)

**Setup:** Limits declared in `apps/monitoring/*-values.yaml`. This scenario shows *why* they exist.

**Steps:**

1. Check baseline: `kubectl -n monitoring top pods` and `kubectl -n monitoring get deploy cart -o jsonpath='{.spec.template.spec.containers[0].resources}'` → `limits: 200m/160Mi`
2. Simulate leak (without removing Git limits): `kubectl -n monitoring exec deploy/cart -- stress --vm 1 --vm-bytes 200M --timeout 30s` (or use `kubectl -n monitoring set resources deployment/cart --limits=memory=512Mi` as temporary validation)
3. Observe: `kubectl -n monitoring get pod -l app=cart` → `OOMKilled`, node remains healthy `kubectl top node` stable
4. Without limits: Leak would cause node pressure → kubelet eviction → affects neighbors
5. Re-apply Git truth: `kubectl -n monitoring rollout restart deployment/cart` → Argo restores Git limits, or push correct values to Git + Kyverno `require-limits.yaml` enforces

**Production mapping:** Helm `values-prod.yaml` + Kyverno policy `require-limits.yaml` enforces limits before app deployment via App-of-Apps sync-wave.

---

## Additional SRE Notes (Interview Challenges)

**Q3 What if k3d cluster deleted manually?** `null_resource` trigger is `filemd5(clusters/observability-cluster.yaml)`. If deleted outside TF, run `terraform apply -replace=null_resource.k3d_cluster`. TF uses local state intentionally for single-machine lab; EKS prod uses S3 backend + DynamoDB lock (documented in `bootstrap/main.tf` L13-L17).

**Q5 Why K8s API listening on 0.0.0.0?** Fixed: `clusters/observability-cluster.yaml` now `kubeAPI.hostIP: 127.0.0.1:6443` for local-only lab. Earlier `0.0.0.0` was for WSL2→Windows routing. Prod EKS uses private endpoint + IAM auth.

**Q6 Why ArgoCD insecure HTTP?** `bootstrap/main.tf` sets `server.insecure: true` intentionally for local lab - Traefik provides `http://argocd.local` → `127.0.0.1`. Annotated `hardening.lab/prod-posture: websecure:443 + cert-manager + TLS + SSO`. Not accidental.

**Q8 MinIO loses data?** Single-node single-disk intentionally. Demonstrates S3 API integration (Loki chunks + Tempo blocks via S3 Put/Get), not durable HA. Loss = old logs/traces gone, pipeline continues, new data flows. Prod: S3 + versioning + replication or MinIO distributed 4+ nodes.

**Q10 Production-grade vs production-oriented?** Repo is production-oriented / production-pattern-focused, not production-grade platform. Patterns (App-of-Apps, LGTM, burn-rate, PDBs, runbooks) transfer to EKS; infra (VPC CNI, EBS CSI, ALB, IRSA, S3 buckets) requires EKS-specific modules. Distinction makes seniority clearer.
```
