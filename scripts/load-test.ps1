param(
  [string]$BaseUrl = "http://shop.local",
  [int]$Users = 3,
  [int]$DurationSec = 0
)

Write-Host "Load test v2 -> $BaseUrl with $Users users (Ctrl+C to stop)" -ForegroundColor Green

$products = @()
try {
  $resp = Invoke-RestMethod -Uri "$BaseUrl/api/products" -TimeoutSec 5
  $products = $resp.products
  if(-not $products){ $products = $resp } # fallback if array directly
  Write-Host "Found $($products.Count) products" -ForegroundColor Cyan
} catch {
  Write-Host "Failed $BaseUrl/api/products : $_" -ForegroundColor Red
  exit 1
}

$start = Get-Date
$jobs = 1..$Users | ForEach-Object {
  Start-Job -ScriptBlock {
    param($BaseUrl, $ProductsJson)
    $products = $ProductsJson | ConvertFrom-Json
    $rand = [Random]::new()

    while ($true) {
      try {
        $null = Invoke-RestMethod -Uri "$BaseUrl/api/products" -TimeoutSec 3 -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds $rand.Next(100,400)

        # CORRECT cart payload
        $p = $products | Get-Random
        $pid = if($p.id){$p.id}else{$p.productId}
        $cartBody = @{ item = @{ productId = $pid; quantity = $rand.Next(1,3) } } | ConvertTo-Json
        $null = Invoke-WebRequest -Uri "$BaseUrl/api/cart" -Method Post -Body $cartBody -ContentType "application/json" -TimeoutSec 5 -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds $rand.Next(200,600)

        # CORRECT checkout payload - 50% of loops
        if($rand.Next(100) -lt 50){
          $checkoutBody = @{
            email = "load-$($rand.Next(10000))@test.com"
            street_address = "1600 Amphitheatre Parkway"
            zip_code = "94043"
            city = "Mountain View"
            state = "CA"
            country = "United States"
            cc_number = "4432-8015-6152-0454"
            cc_cvv = "672"
            cc_expiry_month = "1"
            cc_expiry_year = "2030"
          } | ConvertTo-Json
          $null = Invoke-WebRequest -Uri "$BaseUrl/api/checkout" -Method Post -Body $checkoutBody -ContentType "application/json" -TimeoutSec 8 -ErrorAction SilentlyContinue
        }
      } catch { }
      Start-Sleep -Milliseconds $rand.Next(300,900)
    }
  } -ArgumentList $BaseUrl, ($products | ConvertTo-Json -Depth 5)
}

try {
  while ($true) {
    $elapsed = (Get-Date) - $start
    Write-Host "[$([int]$elapsed.TotalSeconds)s] $Users users running..." -ForegroundColor Yellow
    if($DurationSec -gt 0 -and $elapsed.TotalSeconds -ge $DurationSec){break}
    Start-Sleep 5
  }
} finally {
  $jobs | Stop-Job -ErrorAction SilentlyContinue
  $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
  Write-Host "Stopped" -ForegroundColor Green
}
