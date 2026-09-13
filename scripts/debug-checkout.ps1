param([string]$BaseUrl = "http://shop.local")

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$userId = [guid]::NewGuid().ToString()

Write-Host "BaseUrl: $BaseUrl" -ForegroundColor Cyan
Write-Host "userId: $userId" -ForegroundColor Cyan

# 1. GET products and debug parsing
Write-Host "`n--- 1. GET /api/products ---" -ForegroundColor Yellow
try {
  $raw = Invoke-WebRequest -Uri "$BaseUrl/api/products" -WebSession $session -UseBasicParsing -TimeoutSec 10
  Write-Host "Raw length: $($raw.Content.Length)"
  $allProducts = $raw.Content | ConvertFrom-Json
  if ($allProducts.products) { $allProducts = $allProducts.products }
  Write-Host "Count: $($allProducts.Count)"
  Write-Host "First raw object:"
  $allProducts[0] | Format-List | Out-String | Write-Host

  $productId = $allProducts[0].id
  if (-not $productId) { $productId = $allProducts[0].ID }
  if (-not $productId) { $productId = $allProducts[0].productId }

  # Fallback to known working ID from your curl
  if (-not $productId) {
    Write-Host "id field null, using hardcoded fallback 0PUK6V6EV0" -ForegroundColor Red
    $productId = "0PUK6V6EV0"
  }

  Write-Host "Using productId: $productId" -ForegroundColor Green
} catch {
  Write-Host "FAILED: $_" -ForegroundColor Red
  $productId = "0PUK6V6EV0"
}

# 2. POST cart
Write-Host "`n--- 2. POST /api/cart?currencyCode=USD ---" -ForegroundColor Yellow
$cartPayload = @{
  userId = $userId
  item = @{ productId = $productId; quantity = 1 }
} | ConvertTo-Json -Compress
Write-Host "Payload: $cartPayload"

try {
  $resp = Invoke-WebRequest -Uri "$BaseUrl/api/cart?currencyCode=USD" -Method Post -Body $cartPayload -ContentType "application/json" -WebSession $session -TimeoutSec 10 -UseBasicParsing
  Write-Host "Status: $($resp.StatusCode)" -ForegroundColor Green
  Write-Host "Body: $($resp.Content)"
} catch {
  Write-Host "FAILED: $_" -ForegroundColor Red
  if ($_.Exception.Response) {
    $r = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    Write-Host $r.ReadToEnd() -ForegroundColor Red
  }
}

# 3. GET cart
Write-Host "`n--- 3. GET /api/cart?sessionId=$userId&currencyCode=USD ---" -ForegroundColor Yellow
try {
  $cartResp = Invoke-WebRequest -Uri "$BaseUrl/api/cart?sessionId=$userId&currencyCode=USD" -WebSession $session -UseBasicParsing -TimeoutSec 10
  Write-Host "Status: $($cartResp.StatusCode)" -ForegroundColor Green
  Write-Host "Body: $($cartResp.Content)"
} catch {
  Write-Host "FAILED GET cart: $_" -ForegroundColor Red
  if ($_.Exception.Response) {
    $r = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    $body = $r.ReadToEnd()
    Write-Host "Error body: $body" -ForegroundColor Red

    # Check product-catalog
    Write-Host "`nChecking product-catalog pod..." -ForegroundColor Yellow
    kubectl -n monitoring logs deploy/product-catalog --tail=20
  }
}

# 4. Checkout
Write-Host "`n--- 4. POST /api/checkout?currencyCode=USD ---" -ForegroundColor Yellow
$checkoutPayload = @{
  userId = $userId
  email = "someone@example.com"
  address = @{
    streetAddress = "1600 Amphitheatre Parkway"
    city = "Mountain View"
    state = "CA"
    country = "United States"
    zipCode = "94043"
  }
  creditCard = @{
    creditCardNumber = "4432-8015-6152-0454"
    creditCardCvv = 672
    creditCardExpirationMonth = 1
    creditCardExpirationYear = 2030
  }
  userCurrency = "USD"
} | ConvertTo-Json -Compress
Write-Host "Payload: $checkoutPayload"

try {
  $resp = Invoke-WebRequest -Uri "$BaseUrl/api/checkout?currencyCode=USD" -Method Post -Body $checkoutPayload -ContentType "application/json" -WebSession $session -TimeoutSec 15 -UseBasicParsing
  Write-Host "Status: $($resp.StatusCode)" -ForegroundColor Green
  Write-Host "Body: $($resp.Content)" -ForegroundColor Green
  Write-Host "SUCCESS!" -ForegroundColor Green
} catch {
  Write-Host "FAILED checkout: $_" -ForegroundColor Red
  if ($_.Exception.Response) {
    $r = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    Write-Host "Error body: $($r.ReadToEnd())" -ForegroundColor Red
  }
}