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

# Find OpenSSL — check PATH first, then common Git install locations
$opensslExe = $null
$opensslCandidates = @(
    'openssl',
    'C:\Program Files\Git\usr\bin\openssl.exe',
    'C:\Program Files (x86)\Git\usr\bin\openssl.exe',
    'C:\tools\openssl\openssl.exe'
)
foreach ($candidate in $opensslCandidates) {
    try {
        if ($candidate -eq 'openssl') {
            $null = Get-Command openssl -ErrorAction Stop
            $opensslExe = 'openssl'
        } elseif (Test-Path $candidate) {
            $opensslExe = $candidate
        }
        if ($opensslExe) { break }
    } catch {}
}

if ($opensslExe) {
    Write-Host "Using OpenSSL: $opensslExe" -ForegroundColor Cyan
    & $opensslExe pkcs12 -in $pfxPath -nocerts -out $pemKeyPath -nodes -passin "pass:CertP@ssw0rd!" 2>$null
    & $opensslExe pkcs12 -in $pfxPath -clcerts -nokeys -out $pemCertPath -passin "pass:CertP@ssw0rd!" 2>$null
    Write-Host "PEM files created using OpenSSL" -ForegroundColor Green
} else {
    # .NET fallback — compatible with .NET Framework 4.x (PowerShell 5.1) and .NET 6+
    Write-Host "OpenSSL not found. Using .NET fallback method..." -ForegroundColor Yellow

    # Export certificate (public part) as PEM
    $certBytes = $cert.RawData
    $certPem  = "-----BEGIN CERTIFICATE-----`r`n"
    $certPem += [Convert]::ToBase64String($certBytes, [Base64FormattingOptions]::InsertLineBreaks)
    $certPem += "`r`n-----END CERTIFICATE-----`r`n"
    [IO.File]::WriteAllText($pemCertPath, $certPem)

    # Export private key using RSA parameters — works on all .NET versions
    $rsa = $cert.PrivateKey -as [System.Security.Cryptography.RSACryptoServiceProvider]
    if (-not $rsa) {
        # On PS 7 / .NET 6+ the key may be RSACng — extract via RSACng.ExportParameters
        $rsaCng = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        $params  = $rsaCng.ExportParameters($true)
    } else {
        $params = $rsa.ExportParameters($true)
    }

    # Build PKCS#1 RSA private key DER (works without OpenSSL)
    function Encode-DerInteger([byte[]]$bytes) {
        # Prepend 0x00 if high bit set (unsigned)
        if ($bytes[0] -band 0x80) { $bytes = ,0x00 + $bytes }
        $len = Encode-DerLength $bytes.Length
        return ,0x02 + $len + $bytes
    }
    function Encode-DerLength([int]$len) {
        if ($len -lt 128) { return ,[byte]$len }
        $encoded = @()
        $tmp = $len
        while ($tmp -gt 0) { $encoded = ,([byte]($tmp -band 0xFF)) + $encoded; $tmp = $tmp -shr 8 }
        return ,(0x80 -bor $encoded.Count) + $encoded
    }
    function Strip-Leading-Zeros([byte[]]$b) {
        $i = 0; while ($i -lt $b.Length - 1 -and $b[$i] -eq 0) { $i++ }
        return $b[$i..($b.Length-1)]
    }

    $ver  = Encode-DerInteger @(0)
    $n    = Encode-DerInteger (Strip-Leading-Zeros $params.Modulus)
    $e    = Encode-DerInteger (Strip-Leading-Zeros $params.Exponent)
    $d    = Encode-DerInteger (Strip-Leading-Zeros $params.D)
    $p    = Encode-DerInteger (Strip-Leading-Zeros $params.P)
    $q    = Encode-DerInteger (Strip-Leading-Zeros $params.Q)
    $dp   = Encode-DerInteger (Strip-Leading-Zeros $params.DP)
    $dq   = Encode-DerInteger (Strip-Leading-Zeros $params.DQ)
    $qinv = Encode-DerInteger (Strip-Leading-Zeros $params.InverseQ)

    $inner = $ver + $n + $e + $d + $p + $q + $dp + $dq + $qinv
    $seq   = ,0x30 + (Encode-DerLength $inner.Length) + $inner
    $keyBytes = [byte[]]$seq

    $keyPem  = "-----BEGIN RSA PRIVATE KEY-----`r`n"
    $keyPem += [Convert]::ToBase64String($keyBytes, [Base64FormattingOptions]::InsertLineBreaks)
    $keyPem += "`r`n-----END RSA PRIVATE KEY-----`r`n"
    [IO.File]::WriteAllText($pemKeyPath, $keyPem)

    Write-Host "PEM files created using .NET (no OpenSSL needed)" -ForegroundColor Green
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