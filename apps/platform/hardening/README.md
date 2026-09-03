# Platform Hardening - SRE Production Hardening

This app owns resources that must not be owned by Helm apps to avoid Argo CD SharedResourceWarning.

## Structure

```
argocd/
└── root-app.yaml # Root App-of-Apps -> source.path: apps/monitoring

apps/monitoring/
├── otel-demo.app.yaml # OpenTelemetry demo (owns Deployments)
├── prometheus.app.yaml # kube-prometheus-stack
└── hardening-app.yaml # Platform hardening (owns PDBs)

apps/platform/hardening/
├── 02-poddisruptionbudgets.yaml # PDBs for cart, checkout, frontend, kafka
└── README.md

docs/runbooks/
└── checkout-slo-burning.md # Runbook for Checkout SLO
```

## What is implemented

### 1. Resource Limits

Resource requests/limits are declaratively managed via Helm values in `apps/monitoring/*-values.yaml` (otel-demo, loki, alloy, tempo, minio, prometheus-grafana). All values are GitOps-synced by Argo CD. The `platform-hardening` app owns only PDBs and Kyverno policies to avoid SharedResourceWarning.

Verified via:
```powershell
kubectl -n monitoring get deploy cart -o jsonpath='{.spec.template.spec.containers[0].resources}'
kubectl -n monitoring get sts loki -o jsonpath='{.spec.template.spec.containers[0].resources}'
kubectl -n monitoring get deploy -l app.kubernetes.io/instance=otel-demo -o jsonpath='{range.items[*]}{.metadata.name}: {.spec.template.spec.containers[0].resources}{"\n"}{end}'
```

### 2. PodDisruptionBudgets (PDBs) — Eviction Protection, Not HA

PDBs for `cart`, `checkout`, `frontend`, `kafka` are owned exclusively by the `platform-hardening` app to avoid Argo CD ownership conflicts.

Source: `apps/platform/hardening/02-poddisruptionbudgets.yaml`

```yaml
# cart-pdb, checkout-pdb, frontend-pdb, kafka-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: cart # etc
```

- **Configuration:** `minAvailable: 1` in `monitoring` namespace
- **What it demonstrates:** Voluntary disruption protection (`kubectl drain`, cluster autoscaler, node upgrades). PDB blocks eviction when it would leave 0 healthy replicas.
- **What it does NOT provide:** Workload HA. This is a local k3d lab intentionally running low replica counts (often 1) to stay light on Docker resources. `minAvailable: 1` on a single replica prevents taking the *last* replica away, but does not create a second replica. True HA requires `replicas>=2` + `topologySpreadConstraints` + multi-AZ — pattern documented for EKS, not enabled locally by design.
- **For HA prod (3 replicas):** Use `maxUnavailable: 1` instead.

```powershell
kubectl -n monitoring get pdb
# cart-pdb, checkout-pdb, frontend-pdb, kafka-pdb -> minAvailable: 1
```

### 3. NetworkPolicy - Intentionally Excluded (Design Decision)

**Decision:** No NetworkPolicies in k3d lab.

**Rationale:** Objective of this lab is observability / SRE (traces, metrics, logs, SLOs, chaos) rather than replacing k3d's networking stack. k3d uses Flannel (non-policy-enforcing) by default. Adding Cilium just to tick a security box adds operational complexity without SRE value for this repo.

**Production mapping:**
- CNI: Cilium / Calico with policy enforcement
- Policies: default-deny + explicit allow for frontend->backend, backend->DB, monitoring scrapes
- Documented in `hardening.lab/prod-posture` annotations

**Trade-off accepted:** Lab shows awareness, not enforcement. No security debt hidden.

### 4. Health Probes — Upstream + CI-Validated

Health probes are intentionally **not overridden in `apps/monitoring/otel-demo-values.yaml`**.

The OpenTelemetry Demo is consumed as an upstream Helm dependency at version `0.40.10`. The project does not modify the individual demo application microservices (`cart`, `checkout`, `frontend`, etc.) solely to introduce custom Kubernetes probes.

The rendered upstream chart was inspected to verify the health probes provided by the chart for the following observability workloads:

| Workload | Chart | Liveness | Readiness | Note |
|----------|-------|----------|-----------|------|
| Alloy | grafana/alloy | ✓ | ✓ | Our collector |
| Loki | grafana/loki | ✓ | ✓ | |
| Tempo | grafana/tempo | ✓ | ✓ | |
| Prometheus | kube-prometheus-stack | ✓ | ✓ | |
| Grafana | kube-prometheus-stack | ✓ | ✓ | |
| OTel Demo microservices | opentelemetry-demo | — | — | No probes upstream by design |

This distinction is intentional: the project operates the upstream demo application rather than changing its application-level health-check implementation.

#### Validation

The exact chart version and repository values are rendered in CI:

```bash
helm template otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.10 \
  -f apps/monitoring/otel-demo-values.yaml \
  --namespace monitoring
```

### 5. Runbook
`docs/runbooks/checkout-slo-burning.md` - complete runbook for `CheckoutSLOBurning` alert.

### 6. Ingress Exposure

Current `apps/monitoring/ingress.yaml` uses `web` (HTTP) intentionally for k3d local dev with `*.local` hosts pointing to 127.0.0.1.

Hardening:
- Traefik Middleware `local-only` ipAllowList restricts to loopback + RFC1918
- Annotated `hardening.lab/exposure: local-only`
- Prod posture documented: `websecure` + cert-manager + TLS + WAF/ALB

### 7. GitOps Drift Detection & Self-Healing - Live Evidence

**Config:**
All Applications have:
```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

#### Experiment 2026-09-04 - monitoring/cart:

**Manual Test**

```powershell
PS> kubectl -n monitoring scale deploy cart --replicas=0
deployment.apps/cart scaled

PS> kubectl -n monitoring get deploy cart -w
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
cart   0/1     1            0           2d23h
cart   1/1     1            1           2d23h  # <-- ArgoCD self-healed, no human action

PS> kubectl -n monitoring get deploy cart
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
cart   1/1     1            1           3d
```

**Automated Demo Script:**

```powershell
PS C:\1. OPS\Repos\k3d-observability-lab> bash scripts/demo-self-heal.sh
=== D1 Self-Healing Demo: monitoring/cart ===
1. Current state (desired):
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
cart   1/1     1            1           3d

2. Checking ArgoCD selfHeal config:
    annotations:
      argocd.argoproj.io/sync-wave: "2"
      kubectl.kubernetes.io/last-applied-configuration: |
        {"apiVersion":"argoproj.io/v1alpha1","kind":"Application","metadata":{"annotations":{"argocd.argoproj.io/sync-wave":"2"},"labels":{"argocd.argoproj.io/instance":"root-observability-app"},"name":"alloy","namespace":"argocd"},"spec":{"destination":{"namespace":"monitoring","server":"https://kubernetes.default.svc"},"project":"observability-lab","sources":[{"chart":"alloy","helm":{"valueFiles":["$GitRepo/apps/monitoring/alloy-values.yaml"]},"repoURL":"https://grafana.github.io/helm-charts","targetRevision":"0.9.0"},{"ref":"GitRepo","repoURL":"https://github.com/SwamyVaditya/k3d-observability-lab.git","targetRevision":"main"}],"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}
    creationTimestamp: "2026-08-31T22:17:10Z"
    generation: 462
    labels:
--
      targetRevision: main
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
  status:
    controllerNamespace: argocd
    health:
--
        retry:
          limit: 5
        sync:

3. Simulating drift — scale to 0:
deployment.apps/cart scaled
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
cart   0/0     0            0           3d

4. Watching for ArgoCD self-heal (up to 3min)...
  attempt 1: spec.replicas=0 ready=
  attempt 2: spec.replicas=1 ready=1

✅ Self-healed! ArgoCD restored replicas=1
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
cart   1/1     1            1           3d
```

**Result:** ✅ Drift detected (replicas 0 vs desired 1) → ArgoCD restored to 1 automatically in <60s. No manual kubectl scale --replicas=1 needed.

**Why it matters:** Proves Git is source of truth. Even if someone scales down / deletes manually, cluster converges back.

## Real Production vs Lab

| Item | This Lab | Real Production (EKS) |
|------|----------|------------------------|
| Resource Limits | Helm values `apps/monitoring/*-values.yaml` GitOps-synced | Helm `values-prod.yaml` + Kyverno policy enforcement |
| PDBs | `02-poddisruptionbudgets.yaml` in monitoring ns, minAvailable:1 eviction protection | Helm values + replicas>=2 + topologySpread + maxUnavailable:1 |
| NetworkPolicies | Skipped (flannel) | `platform/network-policies/` + Cilium default-deny |
| Probes | Inherited + CI-validated via helm template | In chart + Kyverno require-probes |
| Runbook | `docs/runbooks/` | Same + linked from alert runbook_url annotation |

In production, hardening is Day 1 - baked into Helm values and enforced by Kyverno/OPA policies synced before apps via App-of-Apps.

## Checklist

- Resource Limits - declarative[x]
- PodDisruptionBudgets - eviction protection[x]
- NetworkPolicies - intentionally skipped for k3d, documented[x]
- Liveness/Readiness - inherited + CI-validated[x]
- Runbook
