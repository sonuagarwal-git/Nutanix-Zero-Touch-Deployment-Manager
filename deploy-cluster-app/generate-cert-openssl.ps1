# Regenerate certificates with proper format using OpenSSL

$certsDir = "E:\SOAAA\ZTIPS\deploy-cluster-app\certs"
cd $certsDir

# Check if OpenSSL is available
$opensslPath = Get-Command openssl -ErrorAction SilentlyContinue

if (-not $opensslPath) {
    Write-Host "ERROR: OpenSSL not found!" -ForegroundColor Red
    Write-Host "Please install OpenSSL from: https://slproweb.com/products/Win32OpenSSL.html" -ForegroundColor Yellow
    Write-Host "Or use: choco install openssl" -ForegroundColor Yellow
    exit 1
}

Write-Host "Converting PFX to PEM format using OpenSSL..." -ForegroundColor Cyan

# Convert PFX to PEM private key (unencrypted)
openssl pkcs12 -in server.pfx -nocerts -out server.key -nodes -password pass:NutanixDeploy2026!

# Convert PFX to PEM certificate
openssl pkcs12 -in server.pfx -clcerts -nokeys -out server.crt -password pass:NutanixDeploy2026!

Write-Host ""
Write-Host "✓ Certificates converted successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Certificate files:" -ForegroundColor Cyan
Write-Host "  Key:  $certsDir\server.key" -ForegroundColor Gray
Write-Host "  Cert: $certsDir\server.crt" -ForegroundColor Gray
Write-Host ""

# Verify the files
if ((Test-Path "server.key") -and (Test-Path "server.crt")) {
    $keyContent = Get-Content "server.key" -Raw
    $certContent = Get-Content "server.crt" -Raw
    
    if ($keyContent -match "BEGIN PRIVATE KEY" -and $certContent -match "BEGIN CERTIFICATE") {
        Write-Host "✓ Certificate format verified - ready to use!" -ForegroundColor Green
    } else {
        Write-Host "⚠ Warning: Certificate format may be incorrect" -ForegroundColor Yellow
    }
}