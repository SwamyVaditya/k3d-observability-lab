# bootstrap/setup-cluster.ps1

Write-Host "Step 1: Creating K3d Observability Cluster..." -ForegroundColor Cyan
k3d cluster create --config ../clusters/observability-cluster.yaml

Write-Host "Step 2: Installing Argo CD..." -ForegroundColor Cyan
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f argocd-install.yaml

Write-Host "Waiting for Argo CD server deployment to be ready..." -ForegroundColor Yellow
kubectl rollout status deployment/argocd-server -n argocd --timeout=120s

Write-Host "Step 3: Retrieving Initial Argo CD Admin Password..." -ForegroundColor Green
$encodedPassword = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
$decodedPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encodedPassword))

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Argo CD Admin Password: $decodedPassword" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "Step 4: Applying GitOps Root Application..." -ForegroundColor Cyan
kubectl apply -f ../argocd/root-app.yaml

Write-Host "Bootstrap complete! Run 'kubectl port-forward svc/argocd-server -n argocd 8080:443' to access the UI." -ForegroundColor Cyan