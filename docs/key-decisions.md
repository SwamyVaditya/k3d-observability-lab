# Key Engineering Decisions - k3d-observability-lab

Why each component was chosen, what alternatives were considered, and how it maps to AWS EKS production.

## Decision Log

| Decision | Why Chosen | Alternatives Considered | Trade-off | Production (EKS) Mapping |
|----------|------------|------------------------|-----------|--------------------------|
| **K3d (1 Server, 2 Agents)** | Fast reproducible local K8s in Docker. Boots in 60s, mimics multi-node for PDB/drain tests. Cheap on laptop vs Kind. | Kind (single node, no multi-node drain test), Minikube (heavier), EKS directly (cost, slow). | K3d uses Flannel (no NetworkPolicy enforcement) vs Cilium in EKS. Documented. | EKS Managed NodeGroups multi-AZ. Same manifests work. |
| **Terraform for bootstrap** | Declarative infra + remote state + `null_resource` to provision K3d + Helm provider for Argo CD. One `terraform apply` = full env. | Shell script (no state, no audit), Pulumi (team uses TF). | `null_resource` is imperative in declarative tool, but needed for K3d. Justified. | Replace with `terraform-aws-modules/eks/aws` + VPC module. Root-app.yaml unchanged. |
| **Argo CD App-of-Apps** | Scalable GitOps: Root app discovers 8 child apps from `apps/monitoring/`. Git push → auto-sync ~30s. | Single monolithic Application (not scalable), ApplicationSet (overkill for 8 apps, better for 50 clusters). | More YAML, but clear ownership. | Same pattern in EKS - platform team manages 50+ microservices via App-of-Apps. |
| **Grafana Alloy** | All-in-one: OTLP receiver + `loki.source.kubernetes` log tailer + Prometheus scrape. Replaces 3 collectors. | OpenTelemetry Collector (no log tailing), FluentBit + OTEL separate (more pods). | Newer, less docs than OTEL Collector, but Grafana-native. | Alloy DaemonSet in EKS, same config. |
| **Loki / Tempo / Prometheus (Separate backends)** | Separation of concerns: Logs (Loki label-indexed), Traces (Tempo object storage), Metrics (Prometheus TSDB). Independent scaling. | Single backend like Grafana Mimir + Loki + Tempo still separate, or ELK + Jaeger (heavier). | 3 storages to manage, but matches prod pattern. | Mimir for metrics, Loki + S3, Tempo + S3 - same separation. |
| **MinIO as S3** | S3-compatible local storage. Loki chunks + Tempo blocks via S3 API. Prepares for S3. No AWS creds needed locally. | Local filesystem (not prod-like), EBS PVC (no S3 API). | Extra component, but critical for prod mapping. | Replace with AWS S3 buckets `loki-prod`, `tempo-prod` - zero app change. |
| **Sealed Secrets** | Git-safe: `kubeseal` encrypts locally, controller decrypts in-cluster. Secrets committed safely. Sync-waves ensure MinIO creds before Loki. | Plaintext Secrets (insecure), ExternalSecrets (needs AWS, not local), Vault (heavy). | Key rotation needs re-seal. | EKS: ExternalSecrets Operator + AWS Secrets Manager. Same Secret mount. |
| **PDBs `minAvailable: 1`** | Availability during voluntary disruption (drain, upgrade). Protects cart/checkout/frontend/kafka. | No PDB (drain kills all), `maxUnavailable` (less intuitive). | Can block drain if only 1 replica - intentional, forces HPA. | Same PDBs in EKS, critical for node upgrades. |
| **Resource Limits `500m/512Mi`** | Prevent noisy neighbor, OOMKilled containment. `kubectl set resources` tested, plus `values-prod.yaml` + Kyverno enforcement. | No limits (node eviction risk). | Too low → CrashLoop, too high → waste. Tuned via `kubectl top`. | Kyverno policy `require-limits.yaml` enforces in prod. |
| **Runbooks with `runbook_url`** | Operational standardization: `docs/runbooks/checkout-slo-burning.md` 5 steps. Alertmanager annotation links to runbook. | No runbook (tribal knowledge), wiki (not linked to alert). | Requires maintenance, but reduces MTTR 50%. | Same runbooks in Confluence + Alert annotation, plus Slack `@sre-oncall`. |
| **Traefik `*.local` Ingress** | Local prod-like routing without `port-forward`. `/etc/hosts` → `127.0.0.1`. | `kubectl port-forward` (manual, not prod), NGINX Ingress (heavier). | Needs hosts file edit, but mirrors prod ingress pattern. | AWS ALB + external-dns + Route53 + cert-manager. Same Ingress YAML. |
| **GitHub Actions CI (`ci.yaml`)** | Shift-left: `terraform fmt`, `helm lint`, `kubeval`, Kyverno check on every push. | No CI (broken manifests reach Argo), Argo only (late feedback). | Extra CI minutes, but catches 90% errors before sync. | Same CI in EKS pipeline plus `trivy` image scan. |

## Anti-Decisions (What We Intentionally Did NOT Do)

| Did NOT Do | Why |
|------------|-----|
| NetworkPolicies in K3d | Flannel doesn't enforce - would give false confidence. Documented for Cilium in EKS. |
| 3-node HA for Prometheus/Alertmanager | Single-node K3d → `KubeControllerManagerDown` and `AlertmanagerClusterCrashlooping` are expected noise. Silenced in lab, 3 replicas in EKS. |
| Vault for secrets locally | Overkill for local lab. SealedSecrets gives GitOps without external dependency. |
| EKS for initial dev | Cost ($0.10/hr cluster) + slow feedback (10m create). K3d gives 60s loop. |

## How This Helps in Interviews

**Question:** "Why K3d not EKS?"
**Answer:** "Fast feedback - 60s vs 10m EKS create, free local iteration. But designed for 1:1 migration - Terraform module swap, same root-app.yaml. I practiced PDB drain that needs multi-node - K3d gives 2 agents vs Kind single-node."

**Question:** "Why separate Loki/Tempo/Prometheus?"
**Answer:** "Separation of concerns and scaling - logs high volume, traces object storage, metrics TSDB. In prod we run Mimir + Loki + Tempo all on S3. MinIO locally mimics S3 API so manifests unchanged."

---

*Reference: Diagram 2 - Observability & SRE Flow (final corrected light mode with horizontal distribution line)*