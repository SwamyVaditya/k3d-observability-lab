# Hardening Summary - k3d-observability-lab v1.0

**Goal:** Production-aware decisions in a local k3d lab.

### 1. Ingress Exposure - Fixed ✅
HTTP documented as local-only (`*.local -> 127.0.0.1` via /etc/hosts). Added annotations `hardening.lab/exposure: local-only` and `hardening.lab/prod-posture: websecure:443 + cert-manager + TLS + WAF + private VPC`. Avoided Traefik Middleware CRD that caused SyncError on k3d.

### 2. GitOps Self-Healing - Positive ✅
**Config:** `prune: true, selfHeal: true` on root + child Applications.

**Live Evidence 2026-09-04 - monitoring/cart:**

```powershell
$ bash scripts/demo-self-heal.sh
=== Self-Healing Demo: monitoring/cart ===
attempt 1: spec.replicas=0
attempt 2: spec.replicas=1
✅ Self-healed! ArgoCD restored replicas=1
```


**Why it matters:** Proves Git is source of truth. Even if someone scales down / deletes manually, cluster converges back.

### 3. Files
- `apps/monitoring/ingress.yaml`
- `apps/platform/hardening/README.md` Section 7
- `scripts/demo-self-heal.sh`

**Interview line:** "I prove GitOps self-heal with live drift experiment, and distinguish lab vs prod posture."

### 4. NetworkPolicy - Intentionally Excluded
No NetworkPolicy in k3d (Flannel). Lab focus is observability/SRE, not CNI replacement. Production mapping is Cilium/Calico with default-deny. Documented as intentional trade-off, not omission.
