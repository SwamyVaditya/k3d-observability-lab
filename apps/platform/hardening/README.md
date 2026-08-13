# Platform Hardening

Production hardening for k3d-observability-lab. All workloads run in `monitoring` namespace.

## Structure

```
argocd/
└── root-app.yaml                # Root App-of-Apps -> source.path: apps/monitoring

apps/monitoring/
├── otel-demo.app.yaml           # OpenTelemetry demo (owns Deployments)
├── prometheus.app.yaml          # kube-prometheus-stack
└── hardening.app.yaml           # Platform hardening (owns PDBs)

apps/platform/hardening/
├── 02-poddisruptionbudgets.yaml  # PDBs for cart, checkout, frontend, kafka
└── README.md

docs/runbooks/
└── checkout-slo-burning.md       # Runbook for Checkout SLO
```

## What is implemented

### 1. Resource Limits
In production, resource limits belong in Helm `values-prod.yaml`:

```yaml
cart:
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits: { cpu: 500m, memory: 512Mi }
```

For this k3d lab, applied imperatively:

```powershell
kubectl -n monitoring set resources deployment cart --requests=cpu=50m,memory=128Mi --limits=cpu=500m,memory=512Mi
kubectl -n monitoring set resources deployment checkout --requests=cpu=50m,memory=128Mi --limits=cpu=500m,memory=512Mi
kubectl -n monitoring set resources deployment frontend --requests=cpu=100m,memory=128Mi --limits=cpu=500m,memory=512Mi
kubectl -n monitoring set resources deployment kafka --requests=cpu=100m,memory=256Mi --limits=cpu=1000m,memory=1Gi
```

### 2. PodDisruptionBudgets
Ensures voluntary disruptions (drain, upgrade) don't take down checkout.

```powershell
kubectl -n monitoring get pdb
# cart-pdb, checkout-pdb, frontend-pdb, kafka-pdb -> minAvailable: 1
```

Managed via Argo CD: `platform-hardening` app.

### 3. NetworkPolicies
Skipped in k3d lab. k3d default CNI (flannel) does not enforce NetworkPolicy.
In production EKS/GKE, would use Cilium/Calico with default-deny.

### 4. Liveness / Readiness Probes
Already present in OpenTelemetry demo charts (`/health` endpoints). Verified:

```powershell
kubectl -n monitoring get deploy cart checkout frontend kafka -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
```

### 5. Runbook
`docs/runbooks/checkout-slo-burning.md` - complete runbook for `CheckoutSLOBurning` alert including k3d-specific issues.

## Real Production vs Lab

| Item | This Lab | Real Production (EKS) |
|------|----------|------------------------|
| Resource Limits | `kubectl set resources` | Helm `values-prod.yaml` + Kyverno policy enforcement |
| PDBs | `02-poddisruptionbudgets.yaml` | Helm values or chart-generated |
| NetworkPolicies | Skipped (flannel) | `platform/network-policies/` + Cilium |
| Probes | Verified | In chart + Kyverno `require-probes` |
| Runbook | `docs/runbooks/` | Same + linked from alert `runbook_url` annotation |

In production, hardening is Day 1 - baked into Helm values and enforced by Kyverno/OPA policies synced before apps via App-of-Apps, not applied as post-deploy patches.

## 5B Checklist

- [x] Resource Limits
- [x] PodDisruptionBudgets
- [x] NetworkPolicies (intentionally skipped for k3d, documented)
- [x] Liveness/Readiness
- [x] Runbook
