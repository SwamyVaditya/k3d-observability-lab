param(
  [string]$BaseUrl = "http://shop.local",
  [int]$Users = 3
)

Write-Host "Load test FINAL v6 -> $BaseUrl with $Users users" -ForegroundColor Green

# Hardcoded known-good product IDs from your shop.local (avoid PS id parsing bug)
$knownProductIds = @("0PUK6V6EV0","1YMWWN1N4O","2ZYFJ3GM2N","66VCHSJNUP","6E92ZMYYFZ","9SIQT8TOJO","L9ECAV7KIM","LS4PSXUNUM","OLJCESPC7Z","HQTGWGPNH4")

# Also try to fetch to verify count
try {
  $raw = Invoke-WebRequest -Uri "$BaseUrl/api/products" -UseBasicParsing -TimeoutSec 10
  $parsed = $raw.Content | ConvertFrom-Json
  if ($parsed.products) { $parsed = $parsed.products }
  Write-Host "Verified $($parsed.Count) products from API" -ForegroundColor Cyan
  # Use API ids if we can extract them via regex (bypass PS bug)
  $regexIds = [regex]::Matches($raw.Content, '"id"\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
  if ($regexIds.Count -ge 5) {
    $knownProductIds = $regexIds
    Write-Host "Using $($knownProductIds.Count) IDs extracted via regex" -ForegroundColor Cyan
  }
} catch {
  Write-Host "Using hardcoded product IDs" -ForegroundColor Yellow
}

$jobs = 1..$Users | ForEach-Object {
  Start-Job -ScriptBlock {
    param($BaseUrl, $ProductIdsJson)
    $productIds = $ProductIdsJson | ConvertFrom-Json
    $rand = [Random]::new()
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $userId = [guid]::NewGuid().ToString()

    try { $null = Invoke-WebRequest -Uri "$BaseUrl/" -WebSession $session -UseBasicParsing -TimeoutSec 5 } catch {}

    while ($true) {
      try {
        # Add 1 random product
        $prodId = $productIds | Get-Random
        $cartPayload = @{userId=$userId; item=@{productId=$prodId; quantity=$rand.Next(1,3)}} | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -Uri "$BaseUrl/api/cart?currencyCode=USD" -Method Post -Body $cartPayload -ContentType "application/json" -WebSession $session -TimeoutSec 5 -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds $rand.Next(200,500)

        # Checkout 70% - with verified cart
        if ($rand.Next(100) -lt 70) {
          $checkoutPayload = @{
            userId=$userId
            email="load-$($rand.Next(10000))@example.com"
            address=@{streetAddress="1600 Amphitheatre Parkway"; city="Mountain View"; state="CA"; country="United States"; zipCode="94043"}
            creditCard=@{creditCardNumber="4432-8015-6152-0454"; creditCardCvv=672; creditCardExpirationMonth=1; creditCardExpirationYear=2030}
            userCurrency="USD"
          } | ConvertTo-Json -Compress

          $null = Invoke-RestMethod -Uri "$BaseUrl/api/checkout?currencyCode=USD" -Method Post -Body $checkoutPayload -ContentType "application/json" -WebSession $session -TimeoutSec 10 -ErrorAction SilentlyContinue
        }
      } catch {}
      Start-Sleep -Milliseconds $rand.Next(600,1200)
    }
  } -ArgumentList $BaseUrl, ($knownProductIds | ConvertTo-Json -Compress)
}

Write-Host "Running $Users users - this will generate Orders/min!" -ForegroundColor Yellow
Write-Host "Check Prometheus: sum by(status) (rate(app_frontend_requests_total{target=~'.*checkout.*'}[5m]))" -ForegroundColor DarkGray
try {
  while ($true) {
    Write-Host "[$(Get-Date -Format HH:mm:ss)] $Users jobs running... shop.local should show orders" -ForegroundColor DarkGray
    Start-Sleep 5
  }
} finally {
  Get-Job | Stop-Job -ErrorAction SilentlyContinue
  Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
}
