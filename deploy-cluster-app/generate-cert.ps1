# Create certs directory
$certsDir = Join-Path $PSScriptRoot "certs"
if (-not (Test-Path $certsDir)) {
    New-Item -ItemType Directory -Path $certsDir | Out-Null
}

# Get hostname and build FQDN
$hostname = $env:COMPUTERNAME
$hostnameLower = $hostname.ToLower()
# Use the machine's DNS domain if available, otherwise just use the hostname
$dnsDomain = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN.ToLower() } else { 'local' }
$fqdn = "$hostname.$dnsDomain"
$fqdnLower = $fqdn.ToLower()

# Get all network IP addresses
$ipAddresses = Get-NetIPAddress -AddressFamily IPv4 | 
    Where-Object {$_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*"} | 
    Select-Object -ExpandProperty IPAddress

# Build DnsName array with all possible names
$dnsNames = @(
    "localhost", 
    "127.0.0.1", 
    $hostname, 
    $hostnameLower,
    $fqdn,
    $fqdnLower
)

# Add all discovered IP addresses
$dnsNames += $ipAddresses

# Remove duplicates
$dnsNames = $dnsNames | Select-Object -Unique

Write-Host "Generating certificate with the following SANs:" -ForegroundColor Cyan
$dnsNames | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }

# Generate self-signed certificate
$cert = New-SelfSignedCertificate `
    -Subject "CN=$hostname" `
    -DnsName $dnsNames `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -NotAfter (Get-Date).AddYears(5) `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -FriendlyName "Nutanix Deployment Web SSL" `
    -HashAlgorithm SHA256 `
    -KeyUsage DigitalSignature, KeyEncipherment, DataEncipherment `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.1")

$certThumbprint = $cert.Thumbprint
Write-Host "Certificate created with thumbprint: $certThumbprint" -ForegroundColor Green

# Export certificate to PFX (with private key)
$pfxPassword = ConvertTo-SecureString -String "CertP@ssw0rd!" -Force -AsPlainText
$pfxPath = Join-Path $certsDir "server.pfx"
Export-PfxCertificate -Cert "Cert:\CurrentUser\My\$certThumbprint" -FilePath $pfxPath -Password $pfxPassword
Write-Host "Certificate exported to: $pfxPath" -ForegroundColor Green

# Export to PEM format for Node.js
$pemKeyPath = Join-Path $certsDir "server.key"
$pemCertPath = Join-Path $certsDir "server.crt"

# Use OpenSSL to convert (if available) or use certutil
try {
    openssl pkcs12 -in $pfxPath -nocerts -out $pemKeyPath -nodes -passin pass:CertP@ssw0rd!
    openssl pkcs12 -in $pfxPath -clcerts -nokeys -out $pemCertPath -passin pass:CertP@ssw0rd!
    Write-Host "PEM files created successfully" -ForegroundColor Green
}
catch {
    Write-Host "OpenSSL not found. Installing using alternative method..." -ForegroundColor Yellow
    
    # Alternative: Export using .NET
    $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    [System.IO.File]::WriteAllBytes($pemCertPath, $certBytes)
    
    # For the key, we need to use a more complex approach
    $rsaKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    $keyBytes = $rsaKey.ExportRSAPrivateKey()
    
    # Convert to PEM format
    $keyPem = "-----BEGIN PRIVATE KEY-----`n"
    $keyPem += [Convert]::ToBase64String($keyBytes, [System.Base64FormattingOptions]::InsertLineBreaks)
    $keyPem += "`n-----END PRIVATE KEY-----"
    [System.IO.File]::WriteAllText($pemKeyPath, $keyPem)
    
    $certPem = "-----BEGIN CERTIFICATE-----`n"
    $certPem += [Convert]::ToBase64String($certBytes, [System.Base64FormattingOptions]::InsertLineBreaks)
    $certPem += "`n-----END CERTIFICATE-----"
    [System.IO.File]::WriteAllText($pemCertPath, $certPem)
    
    Write-Host "PEM files created using .NET" -ForegroundColor Green
}

Write-Host ""
Write-Host "SSL Certificate Setup Complete!" -ForegroundColor Green
Write-Host "Certificate files location: $certsDir" -ForegroundColor Cyan
Write-Host "Certificate Thumbprint: $certThumbprint" -ForegroundColor Cyan
Write-Host ""
Write-Host "Note: This is a self-signed certificate." -ForegroundColor Yellow
Write-Host ""
Write-Host "To avoid browser warnings, you have two options:" -ForegroundColor Cyan
Write-Host ""
Write-Host "Option 1 - In the browser (Quick):" -ForegroundColor White
Write-Host "  1. Click 'Advanced' on the warning page" -ForegroundColor Gray
Write-Host "  2. Click 'Proceed to $hostname (unsafe)'" -ForegroundColor Gray
Write-Host ""
Write-Host "Option 2 - Install certificate as trusted (Recommended):" -ForegroundColor White  
Write-Host "  Run this command with Administrator privileges:" -ForegroundColor Gray
Write-Host "  `$cert = Get-ChildItem Cert:\CurrentUser\My\$certThumbprint" -ForegroundColor Yellow
Write-Host "  Export-Certificate -Cert `$cert -FilePath `"$certsDir\server.cer`"" -ForegroundColor Yellow
Write-Host "  Import-Certificate -FilePath `"$certsDir\server.cer`" -CertStoreLocation Cert:\LocalMachine\Root" -ForegroundColor Yellow
Write-Host ""