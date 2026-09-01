# Platform Hardening - SRE Production Hardening

This app owns resources that must not be owned by Helm apps to avoid Argo CD SharedResourceWarning.

## Structure

```
argocd/
└── root-app.yaml # Root App-of-Apps -> source.path: apps/monitoring

apps/monitoring/
├── otel-demo.app.yaml # OpenTelemetry demo (owns Deployments)
├── prometheus.app.yaml # kube-prometheus-stack
└── hardening.app.yaml # Platform hardening (owns PDBs)

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

### 3. NetworkPolicies
Skipped in k3d lab. k3d default CNI (flannel) does not enforce NetworkPolicy.
In production EKS/GKE, would use Cilium/Calico with default-deny.

### 4. Health Probes — Owned Declaratively + CI-Validated

Liveness and readiness probes are **owned declaratively** in `apps/monitoring/otel-demo-values.yaml` for all critical workloads.

The upstream chart `0.40.10` defaults to empty probes (`livenessProbe: {}` / `readinessProbe: {}`), so probes must be explicitly set in values. This repo sets `httpGet` probes on `/health:8080` for Go/Node services and `/` on `:9092` for Kafka to satisfy chart schema validation.

Validated in two places:
1. **Template**: `helm template otel-demo open-telemetry/opentelemetry-demo --version 0.40.10 -f apps/monitoring/otel-demo-values.yaml --namespace monitoring` must contain `livenessProbe` and `readinessProbe`
2. **Live cluster**: `kubectl -n monitoring get deploy cart -o yaml | grep -A3 livenessProbe`

CI job `validate-hardening` in `.github/workflows/ci.yaml` templates the chart with `--version 0.40.10` and asserts all critical Deployments (`cart`, `checkout`, `frontend`, `frontend-proxy`, `payment`, `kafka`) contain probes and `resources.requests/limits`. The build fails if hardening is missing.

```bash
# Template validation (no cluster needed)
helm template otel-demo open-telemetry/opentelemetry-demo --version 0.40.10 \
  -f apps/monitoring/otel-demo-values.yaml --namespace monitoring > /tmp/otel-demo.yaml
grep -A3 "livenessProbe:" /tmp/otel-demo.yaml | head -20

# Live cluster verification
kubectl -n monitoring get deploy cart -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}'
kubectl -n monitoring get deploy cart -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}'
```

### 5. Runbook
`docs/runbooks/checkout-slo-burning.md` - complete runbook for `CheckoutSLOBurning` alert.

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
