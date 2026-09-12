param(
  [string]$BaseUrl = "http://shop.local",
  [int]$Users = 5,
  [int]$DurationSec = 0 # 0 = infinite
)

Write-Host "Load test -> $BaseUrl with $Users users (Ctrl+C to stop)" -ForegroundColor Green

$products = @()
try {
  $products = (Invoke-RestMethod -Uri "$BaseUrl/api/products" -TimeoutSec 5).products
  Write-Host "Found $($products.Count) products" -ForegroundColor Cyan
} catch {
  Write-Host "Failed to fetch products from $BaseUrl/api/products : $_" -ForegroundColor Red
  Write-Host "Try: kubectl -n monitoring port-forward svc/frontend-proxy 8080:8080 and set -BaseUrl http://localhost:8080"
  exit 1
}

$start = Get-Date
$jobs = 1..$Users | ForEach-Object {
  Start-Job -ScriptBlock {
    param($BaseUrl, $ProductsJson)
    $products = $ProductsJson | ConvertFrom-Json

    while ($true) {
      try {
        # 1. Browse
        $null = Invoke-RestMethod -Uri "$BaseUrl/api/products" -TimeoutSec 3 -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds (Get-Random -Min 100 -Max 400)

        # 2. View cart / add to cart
        $p = $products | Get-Random
        $body = @{ productId = $p.id; quantity = (Get-Random -Min 1 -Max 3) } | ConvertTo-Json
        $null = Invoke-WebRequest -Uri "$BaseUrl/api/cart" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 3 -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds (Get-Random -Min 200 -Max 500)

        # 3. Checkout - 70% of iterations (this populates SLO + Business KPIs)
        if ((Get-Random -Min 0 -Max 100) -lt 70) {
          $checkoutBody = @{
            email = "load@test.com"
            address = @{ street="123 Test"; city="Hyd"; country="IN"; zip="500001" }
            creditCard = @{ number="4111111111111111"; expiryMonth=12; expiryYear=2030; cvv="123" }
          } | ConvertTo-Json -Depth 5
          $null = Invoke-WebRequest -Uri "$BaseUrl/api/checkout" -Method Post -Body $checkoutBody -ContentType "application/json" -TimeoutSec 5 -ErrorAction SilentlyContinue
        }
      } catch { }
      Start-Sleep -Milliseconds (Get-Random -Min 200 -Max 800)
    }
  } -ArgumentList $BaseUrl, ($products | ConvertTo-Json -Depth 5)
}

try {
  while ($true) {
    $elapsed = (Get-Date) - $start
    $rps = [math]::Round((Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction SilentlyContinue).CounterSamples.CookedValue,1)
    Write-Host "[$([int]$elapsed.TotalSeconds)s] Running $Users users... Jobs: $($jobs.State -join ',')" -ForegroundColor Yellow
    if ($DurationSec -gt 0 -and $elapsed.TotalSeconds -ge $DurationSec) { break }
    Start-Sleep 5
  }
} finally {
  $jobs | Stop-Job -ErrorAction SilentlyContinue
  $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
  Write-Host "Load test stopped" -ForegroundColor Green
}
