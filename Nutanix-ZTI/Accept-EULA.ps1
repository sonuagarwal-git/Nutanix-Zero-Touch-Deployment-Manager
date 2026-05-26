<#
.SYNOPSIS
    Accepts the EULA on a Nutanix Prism Element cluster (newly deployed).

.DESCRIPTION
    Uses the Prism Element v1 REST API to accept the End User License Agreement.
    This must be run against each Prism Element cluster VIP individually.
    This is NOT for Prism Central — PC uses a different v4 licensing API.

.PARAMETER ConfigFile
    Path to the cluster JSON config file. The cluster VIP is read from network.cluster_vip.

.PARAMETER Username
    Prism Element admin username (default: admin).

.PARAMETER Password
    Prism Element admin password.

.PARAMETER EulaUserName
    Full name of the person accepting the EULA. If not provided, read from config file (eula.username).

.PARAMETER EulaJobTitle
    Job title of the person accepting the EULA. If not provided, read from config file (eula.job_title).

.PARAMETER EulaCompanyName
    Company name for the EULA acceptance. If not provided, read from config file (eula.company_name).

.EXAMPLE
    .\Accept-NutanixEULA.ps1 -ConfigFile ".\Configs\my-cluster.json" -Password "MyPass!" `
        -EulaUserName "John Doe" -EulaJobTitle "Infrastructure Engineer" -EulaCompanyName "ACME Corp"

.NOTES
    Author: Sonu Agarwal
    Date: Mar 15, 2026
    Version: 1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$Username = "admin",

    [Parameter(Mandatory = $false)]
    [string]$Password = "Nutanix/4u",

    [Parameter(Mandatory = $false)]
    [string]$EulaUserName = "",

    [Parameter(Mandatory = $false)]
    [string]$EulaJobTitle = "",

    [Parameter(Mandatory = $false)]
    [string]$EulaCompanyName = ""
)

# Load cluster_vip from config file
$config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
$cluster_vip = $config.network.cluster_vip
if (-not $cluster_vip) {
    Write-Host "ERROR: 'network.cluster_vip' not found in config file: $ConfigFile" -ForegroundColor Red
    exit 1
}

# Resolve EULA fields — parameter overrides config, config is required if parameter not supplied
if (-not $EulaUserName)    { $EulaUserName    = $config.eula.username }
if (-not $EulaJobTitle)    { $EulaJobTitle    = $config.eula.job_title }
if (-not $EulaCompanyName) { $EulaCompanyName = $config.eula.company_name }

$missing = @()
if (-not $EulaUserName)    { $missing += 'eula.username' }
if (-not $EulaJobTitle)    { $missing += 'eula.job_title' }
if (-not $EulaCompanyName) { $missing += 'eula.company_name' }
if ($missing.Count -gt 0) {
    Write-Host "ERROR: The following required EULA fields are missing from the config file and were not supplied as parameters:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host "Add an 'eula' section to your config JSON:" -ForegroundColor Yellow
    Write-Host '  "eula": { "username": "Full Name", "job_title": "Job Title", "company_name": "Company" }' -ForegroundColor Yellow
    exit 1
}

# Build Basic Auth header
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${Username}:${Password}"))
$headers = @{
    "Authorization" = "Basic $base64Auth"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
}

$baseUrl = "https://${cluster_vip}:9440/PrismGateway/services/rest/v1"

# ── Wait for Prism Element to become accessible (freshly created clusters need time) ─────
Write-Host "`n[0/2] Waiting for Prism Element to become accessible on $cluster_vip..." -ForegroundColor Cyan
$peReady      = $false
$peMaxWaitMin = 2
$peDeadline   = (Get-Date).AddMinutes($peMaxWaitMin)
$peTestUrl    = "https://${cluster_vip}:9440/PrismGateway/services/rest/v1/eulas"
while ((Get-Date) -lt $peDeadline) {
    try {
        $null = Invoke-RestMethod -Uri $peTestUrl -Method GET -Headers $headers `
            -SkipCertificateCheck -TimeoutSec 10 -ErrorAction Stop
        $peReady = $true
        break
    } catch {
        $msg = $_.Exception.Message
        # A proper HTTP error (4xx/5xx) means PE is up and responding
        if ($_.Exception.Response -ne $null) {
            $peReady = $true
            break
        }
        $remaining = [int](($peDeadline - (Get-Date)).TotalSeconds)
        Write-Host "  PE not yet ready (${remaining}s left) — $msg" -ForegroundColor DarkGray
        Start-Sleep -Seconds 20
    }
}
if (-not $peReady) {
    Write-Host "  ERROR: Prism Element at $cluster_vip did not become accessible within $peMaxWaitMin minutes." -ForegroundColor Red
    exit 1
}
Write-Host "  Prism Element is accessible." -ForegroundColor Green
# ─────────────────────────────────────────
Write-Host "`n[1/2] Checking current EULA status on $cluster_vip..." -ForegroundColor Cyan
try {
    $eulaStatus = Invoke-RestMethod -Uri "$baseUrl/eulas" `
        -Method GET -Headers $headers -SkipCertificateCheck -ErrorAction Stop

    if ($eulaStatus.userDetailsList -and $eulaStatus.userDetailsList.Count -gt 0) {
        Write-Host "  EULA already accepted by: $($eulaStatus.userDetailsList[0].username)" -ForegroundColor Yellow
        Write-Host "  No action needed." -ForegroundColor Yellow
        exit 0
    }
    else {
        Write-Host "  EULA not yet accepted. Proceeding..." -ForegroundColor Green
    }
}
catch {
    # Some builds return 404 or 500 if not yet configured — treat as not accepted
    Write-Host "  Could not retrieve EULA status (cluster may be freshly deployed). Proceeding..." -ForegroundColor Yellow
}

# ── Step 2: Accept EULA ────────────────────────────────────────────────────────
Write-Host "`n[2/2] Accepting EULA on $cluster_vip..." -ForegroundColor Cyan

$body = @{
    username    = $EulaUserName
    companyName = $EulaCompanyName
    jobTitle    = $EulaJobTitle
} | ConvertTo-Json

try {
    $result = Invoke-RestMethod -Uri "$baseUrl/eulas/accept" `
        -Method POST -Headers $headers -Body $body -SkipCertificateCheck -ErrorAction Stop

    Write-Host "  EULA accepted successfully." -ForegroundColor Green
    Write-Host "  Response: $($result | ConvertTo-Json -Compress)" -ForegroundColor Gray
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $errBody    = $_.ErrorDetails.Message
    Write-Host "  ERROR accepting EULA (HTTP $statusCode): $errBody" -ForegroundColor Red
    exit 1
}

exit 0

