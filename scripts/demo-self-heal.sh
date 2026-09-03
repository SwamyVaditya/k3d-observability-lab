#!/usr/bin/env bash
set -e
NS="monitoring"
DEPLOY="cart"

echo "=== D1 Self-Healing Demo: $NS/$DEPLOY ==="

echo "1. Current state (desired):"
kubectl -n $NS get deploy $DEPLOY

echo ""
echo "2. Checking ArgoCD selfHeal config:"
kubectl -n argocd get applications -o yaml | grep -A3 -B3 "selfHeal\|prune" | head -n 20

echo ""
echo "3. Simulating drift — scale to 0:"
kubectl -n $NS scale deploy $DEPLOY --replicas=0
kubectl -n $NS get deploy $DEPLOY

echo ""
echo "4. Watching for ArgoCD self-heal (up to 3min)..."
for i in {1..18}; do
  replicas=$(kubectl -n $NS get deploy $DEPLOY -o jsonpath='{.spec.replicas}')
  ready=$(kubectl -n $NS get deploy $DEPLOY -o jsonpath='{.status.readyReplicas}')
  echo "  attempt $i: spec.replicas=$replicas ready=$ready"
  if [ "$replicas" != "0" ]; then
    echo ""
    echo "✅ Self-healed! ArgoCD restored replicas=$replicas"
    kubectl -n $NS get deploy $DEPLOY
    exit 0
  fi
  sleep 10
done

echo "❌ Not self-healed in 3min - check argocd app"
kubectl -n argocd get app
exit 1