# Architecture - k3d-observability-lab

One-pager for recruiters & SRE interviewers - what it is, why each piece, how it fails and recovers.

## TL;DR (90-sec pitch)

Production-grade **GitOps observability lab** on K3d - GitOps and SRE patterns transfer to EKS, infra needs EKS modules.

**Flow:** Git push → Terraform creates K3d (1 Server, 2 Agents) + Argo CD → Argo App-of-Apps discovers 8 apps → OTel Demo (11 microservices) emits OTLP → Alloy collects → Loki (logs) / Tempo (traces) / Prometheus (metrics) store in MinIO S3 → Grafana visualizes with exemplars → Prometheus fires `CheckoutSLOBurning` → Alertmanager → Slack + Runbook → PDBs keep it alive.

**Designed for:** Practicing GitOps and SRE patterns locally that transfer to managed K8s like EKS (app layer portable, infra layer needs EKS modules).

## Diagrams

### Diagram 1 - GitOps Workflow (with Production Hardening)

![Diagram 1 - GitOps](../docs/images/diagram1_gitops.png)

GitHub `main` → Terraform `bootstrap/main.tf` provisions K3d + Argo CD → K3d Cluster → Argo Root App → 8 child apps: `otel-demo` • `prometheus` • `dashboards` • `alloy` • `loki` • `tempo` • `minio` • `hardening` (PDBs + Limits + Kyverno).

### Diagram 2 - Observability & SRE Flow (Final Corrected Light Mode)

![Diagram 2 - Observability](../docs/images/diagram2_light_new.png)

```
OTel Demo (frontend/checkout/cart/kafka) --OTLP--> Alloy --horizontal line--> 
  ├─> Loki --chunks S3--> MinIO bucket loki - - logs - -> Grafana
  ├─> Tempo --blocks S3--> MinIO bucket tempo - - traces - -> Grafana
  └─> Prometheus - - metrics - -> Grafana
Prometheus --firing: CheckoutSLOBurning--> Alertmanager --webhook+runbook_url--> Slack #alerts --runbook--> Runbook SLO Burn-down -.-> Grafana
```

## Components (What & Why)

| Layer | Component | Role | Why This |
|-------|-----------|------|----------|
| **Provisioning** | K3d (1 server + 2 agents) | Local multi-node K8s | 60s boot, tests PDB drain (Kind single-node can't). See key-decisions.md |
|  | Terraform `bootstrap/main.tf` | Declarative bootstrap | One `apply` = K3d + Argo CD. App layer transfers to EKS; infra needs VPC/CNI/EBS/ALB modules. |
|  | Traefik `*.local` | Local ingress | `grafana.local` via `/etc/hosts` - avoids port-forward, similar routing pattern to ALB but not same implementation. |
| **GitOps** | Argo CD Root App | App-of-Apps | Discovers 8 apps from `apps/monitoring/`. Git push → sync 30s. |
| | 8 Child Apps | Helm releases | otel-demo (SUT), prometheus, loki, tempo, alloy, minio, dashboards, hardening. |
| | SealedSecrets | Git-safe secrets | `minio-sealed-secret.yaml` + `sealed-alertmanager-slack.yaml` + sync-waves. |
| **Observability** | OTel Demo (11 svc) | System Under Test | frontend→checkout→cart→kafka emitting OTLP - real failure injection. |
| | Alloy | Collector | One binary: OTLP receiver + k8s log tailer + metrics scrape. |
| | Loki + MinIO bucket loki | Logs | Chunks via S3 Put/Get, LogQL in Grafana. |
| | Tempo + MinIO bucket tempo | Traces | Blocks via S3, TraceQL, shows kafka latency. |
| | Prometheus | Metrics | TSDB, `checkout_failure_ratio` PromQL, exemplars to Tempo. |
| | Grafana | Visualization | Logs|Traces|Metrics correlation via traceID. |
| **SRE** | Alertmanager | Routing | Handles `firing: CheckoutSLOBurning`, webhook + `runbook_url`. |
| | Slack #alerts | Incident | Alert + runbook link + @sre-oncall. |
| | Runbook `checkout-slo-burning.md` | Standard response | 5 steps: dashboard → Tempo → Loki → PDB/HPA → mitigate. |
| | PDBs `minAvailable:1` | Availability | cart/checkout/frontend/kafka stay alive during voluntary drain. |
| | Resource Limits | Noisy neighbor protection | `500m/512Mi`, Kyverno `require-limits.yaml` enforces. |

Full decision table with alternatives: [key-decisions.md](./key-decisions.md)

## Failure Modes & Recovery (How SREs Work)

See [failure-scenarios.md](./failure-scenarios.md) for 7 hands-on drills. Summary:

| Scenario | Failure | Detection | Recovery |
|----------|---------|-----------|----------|
| 1. Checkout SLO Burn | cart failure rate 30% | Prometheus `checkout_failure_ratio >5%` → Tempo trace kafka timeout → Loki exception | `git revert` → Argo sync 30s |
| 2. Pod Unhealthy | Readiness 500 | `KubePodNotReady`, endpoint removed | Fix env → ready → endpoint re-added |
| 3. Node Disruption | `kubectl drain` | PDB `ALLOWED DISRUPTIONS 0` blocks full kill | `uncordon`, shop stays up |
| 4. GitOps Drift | `kubectl scale cart --replicas=5` | Argo OutOfSync diff `1→5` | Argo SYNC self-heal → 1 |
| 5. Config Deployment | `frontend.replicas:2` in Git | CI `helm lint` + Argo OutOfSync | Argo sync → 2 pods |
| 6. Secret Rotation | MinIO creds leak | SealedSecrets rotation via `kubeseal` | New sealed secret → MinIO restart → Loki still writes |
| 7. Resource Exhaustion | No limits + memory leak | Node memory spike, eviction | Re-apply limits → OOMKilled contained |

**Screenshots (after rerun):** `docs/images/failure-scenarios/` - Tempo trace, PDB drain block, Argo drift diff.

## Production Readiness - What Transfers vs What Changes

**What transfers (application layer - portable to EKS):**
GitOps App-of-Apps structure, Helm values (`apps/monitoring/*.values.yaml`), PDBs, resource limits, probes, LGTM correlation (Alloy → Loki/Tempo/Prometheus), dashboards, runbooks with `runbook_url`. These manifests run unchanged in EKS.

**What changes (infrastructure layer - requires EKS-specific implementation):**

| Concern | K3d Lab (local) | AWS EKS (production) | Gap |
|---------|-----------------|----------------------|-----|
| Networking | Flannel bridge, simple CNI | VPC CNI, ENI/IP management, Security Groups, Cilium eBPF | IP allocation, NetworkPolicy enforcement, service mesh |
| Storage | k3d Docker volume, hostPath, MinIO on single host | EBS CSI Driver GP3, EFS, S3 with IRSA, StorageClasses, snapshots | Durability, multi-AZ, performance |
| Ingress | Traefik NodePort + `/etc/hosts` `*.local` | AWS LB Controller, ALB/NLB, ACM certs, WAF, Route53 external-dns | TLS, L4/L7, global DNS |
| Identity | kubeconfig only, SealedSecrets | IRSA (IAM Roles for Service Accounts), OIDC provider, ExternalSecrets + Secrets Manager | No IAM in K3d, S3 access via IRSA in EKS |
| Cluster lifecycle | `k3d cluster create` 60s, K3s binary | EKS managed control plane, version upgrades, addons, nodegroups, Karpenter, Fargate | Control plane logs, etcd backup, upgrade strategy |
| Scaling | Manual agents | Cluster Autoscaler / Karpenter, HPA with custom metrics | |

Architectural **patterns** transfer, infrastructure **implementation** does not map 1:1. Lab intentionally optimizes for fast local feedback (60s) over prod parity to practice SRE workflows.


## For Recruiters / Interviewers

It demonstrates:
- **Build local that can be adapted to managed Kubernetes environments such as Amazon EKS** - Terraform + Argo same pattern
- **Debug real GitOps failure** - Resolved Argo CD `SharedResourceWarning` by isolating PDB ownership to hardening app, preventing dual ownership
- **Correlate LGTM** - Exemplars linking metric spike → traceID → log exception
- **Think SRE** - PDBs, limits, `runbook_url`, error budget, Kyverno policy-as-code
- **Document decisions** - Why K3d vs Kind, Alloy vs OTEL, MinIO S3, anti-decisions

## Docs Index

- [README.md](../README.md) - Quick start + badges
- [key-decisions.md](./key-decisions.md) - Why each component, alternatives, trade-offs
- [failure-scenarios.md](./failure-scenarios.md) - 7 hands-on SRE exercises with commands
- [architecture.md](./architecture.md) - This one-pager
- [runbooks/checkout-slo-burning.md](./runbooks/checkout-slo-burning.md) - Incident response
```
