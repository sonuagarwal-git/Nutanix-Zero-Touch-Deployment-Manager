#Requires -Version 7.0
<#
.SYNOPSIS
    Sets or updates the Data Service IP on a Nutanix cluster via the v4.2 clustermgmt API.

.DESCRIPTION
    Uses the Nutanix v4.2 REST API (Prism Central) to find a cluster by name and update
    its externalDataServiceIp. The script performs three calls:
      1. GET /api/clustermgmt/v4.2/config/clusters        → find cluster extId
      2. GET /api/clustermgmt/v4.2/config/clusters/{extId} → fetch current state + ETag
      3. PUT /api/clustermgmt/v4.2/config/clusters/{extId} → update externalDataServiceIp

    You can pass credentials and the target cluster directly, or point to an existing
    ZTI config JSON file and the values will be read from it.

.PARAMETER ConfigFile
    Path to a ZTI cluster config JSON file. When provided, PrismCentralUrl, Username,
    Password and ClusterName are read from the file (but can still be overridden).

.PARAMETER PrismCentralUrl
    URL of Prism Central, e.g. https://10.0.113.220:9440

.PARAMETER Username
    Prism Central admin username (default: admin)

.PARAMETER Password
    Prism Central admin password

.PARAMETER ClusterName
    Name of the cluster to update. Must match the name registered in Prism Central.

.PARAMETER DataServiceIP
    The IPv4 address to set as the cluster Data Service IP.

.PARAMETER DryRun
    Validates and shows what would be sent without making any changes.

.EXAMPLE
    # Using a ZTI config file
    .\Set-DataServiceIP.ps1 -ConfigFile .\Configs\DKCDC-1P-NTXTEST-03.json -DataServiceIP 10.0.113.130

.EXAMPLE
    # Supplying all parameters directly
    .\Set-DataServiceIP.ps1 `
        -PrismCentralUrl https://10.0.113.220:9440 `
        -Username admin `
        -Password 'CHANGE_ME' `
        -ClusterName DKCDC-1P-NTXTEST-03 `
        -DataServiceIP 10.0.113.130

.EXAMPLE
    # Dry-run: validate without changing anything
    .\Set-DataServiceIP.ps1 -ConfigFile .\Configs\DKCDC-1P-NTXTEST-03.json -DataServiceIP 10.0.113.130 -DryRun
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigFile,

    [Parameter()]
    [string]$PrismCentralUrl,

    [Parameter()]
    [string]$Username = 'admin',

    [Parameter()]
    [string]$Password,

    [Parameter()]
    [string]$ClusterName,

    # Optional when -ConfigFile is supplied and contains network.data_service_ip
    [Parameter()]
    [ValidatePattern('(^$)|(^\d{1,3}(\.\d{1,3}){3}$)')]
    [string]$DataServiceIP,

    [Parameter()]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Ignore self-signed certificate errors
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
$PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
$PSDefaultParameterValues['Invoke-WebRequest:SkipCertificateCheck'] = $true

#region ── Helper: console output ─────────────────────────────────────────────

function Write-Step   { param([string]$Msg) Write-Host "  ► $Msg" -ForegroundColor Cyan    }
function Write-Ok     { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green   }
function Write-Warn   { param([string]$Msg) Write-Host "  ⚠ $Msg" -ForegroundColor Yellow  }
function Write-Fail   { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor Red     }
function Write-Detail { param([string]$Msg) Write-Host "    $Msg"  -ForegroundColor Gray    }

#endregion

#region ── Step 0: Resolve parameters from config file (if provided) ──────────

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "       Nutanix – Set Cluster Data Service IP  (v4.2 API)      " -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if ($ConfigFile) {
    Write-Step "Reading configuration from: $ConfigFile"

    if (-not (Test-Path $ConfigFile)) {
        Write-Fail "Config file not found: $ConfigFile"
        exit 1
    }

    try {
        $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-Fail "Failed to parse JSON config: $_"
        exit 1
    }

    # Only apply from file if the caller did not already supply the value
    if (-not $PrismCentralUrl -and $cfg.prism_central.url)      { $PrismCentralUrl = $cfg.prism_central.url      }
    if ($Username -eq 'admin' -and $cfg.prism_central.username) { $Username         = $cfg.prism_central.username }
    if (-not $Password        -and $cfg.prism_central.password) { $Password         = $cfg.prism_central.password }
    if (-not $ClusterName     -and $cfg.clusterName)            { $ClusterName      = $cfg.clusterName            }
    # Read Data Service IP from network.data_service_ip if not supplied on command line
    if (-not $DataServiceIP -and
        $cfg.PSObject.Properties['network'] -and
        $cfg.network.PSObject.Properties['data_service_ip'] -and
        $cfg.network.data_service_ip) {
        $DataServiceIP = $cfg.network.data_service_ip
    }

    Write-Ok "Config loaded"
}

#endregion

#region ── Step 1: Validate required parameters ───────────────────────────────

$missing = @()
if (-not $PrismCentralUrl) { $missing += '-PrismCentralUrl' }
if (-not $Password)        { $missing += '-Password' }
if (-not $ClusterName)     { $missing += '-ClusterName' }
if (-not $DataServiceIP)   { $missing += '-DataServiceIP (or network.data_service_ip in config file)' }

if ($missing.Count -gt 0) {
    Write-Fail "Missing required parameters: $($missing -join ', ')"
    Write-Host ""
    Write-Host "  Provide them directly or point to a ZTI config file with -ConfigFile." -ForegroundColor Yellow
    exit 1
}

Write-Detail "Prism Central : $PrismCentralUrl"
Write-Detail "Cluster Name  : $ClusterName"
Write-Detail "Data Svc IP   : $DataServiceIP"
Write-Host ""

#endregion

#region ── Step 2: Build auth header ─────────────────────────────────────────

$base64Creds = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${Username}:${Password}")
)
$headers = @{
    'Authorization' = "Basic $base64Creds"
    'Content-Type'  = 'application/json'
    'Accept'        = 'application/json'
}

#endregion

#region ── Step 3: GET cluster list → find extId ─────────────────────────────

Write-Step "Fetching cluster list from Prism Central..."

$listUrl = "$PrismCentralUrl/api/clustermgmt/v4.2/config/clusters"

try {
    $listResponse = Invoke-RestMethod `
        -Uri     $listUrl `
        -Method  GET `
        -Headers $headers `
        -TimeoutSec 30
}
catch {
    Write-Fail "Could not reach cluster list endpoint: $_"
    Write-Detail "URL: $listUrl"
    exit 1
}

# The v4.2 API wraps results in a 'data' array
$clusters = if ($listResponse.data) { $listResponse.data } else { @($listResponse) }

$target = $clusters | Where-Object { $_.name -eq $ClusterName } | Select-Object -First 1

if (-not $target) {
    Write-Fail "Cluster '$ClusterName' not found in Prism Central."
    Write-Warn "Available clusters:"
    $clusters | ForEach-Object { Write-Detail "  • $($_.name)  [$($_.extId)]" }
    exit 1
}

$extId = $target.extId
Write-Ok "Found cluster '$ClusterName'"
Write-Detail "extId : $extId"
Write-Host ""

#endregion

#region ── Step 4: GET cluster by extId → fetch full object + ETag ───────────

Write-Step "Fetching current cluster configuration + ETag..."

$clusterUrl = "$PrismCentralUrl/api/clustermgmt/v4.2/config/clusters/$extId"

try {
    $getResponse = Invoke-WebRequest `
        -Uri     $clusterUrl `
        -Method  GET `
        -Headers $headers `
        -TimeoutSec 30
}
catch {
    Write-Fail "Failed to fetch cluster details: $_"
    exit 1
}

# Extract ETag (required for optimistic concurrency control on PUT).
# In PowerShell 7, Invoke-WebRequest returns header values as string[] —
# take the first element to ensure we pass a plain string to If-Match.
$etag = [string]($getResponse.Headers['ETag']  | Select-Object -First 1)
if (-not $etag) {
    $etag = [string]($getResponse.Headers['Etag'] | Select-Object -First 1)
}

$clusterObj = $getResponse.Content | ConvertFrom-Json

# Report current Data Service IP if already set (navigate safely without strict mode issues)
$currentDSIP = $null
try {
    $inner = if ($clusterObj.PSObject.Properties['data']) { $clusterObj.data } else { $clusterObj }
    if ($inner.PSObject.Properties['network'] -and
        $inner.network.PSObject.Properties['externalDataServiceIp'] -and
        $inner.network.externalDataServiceIp.PSObject.Properties['ipv4'] -and
        $inner.network.externalDataServiceIp.ipv4.PSObject.Properties['value']) {
        $currentDSIP = $inner.network.externalDataServiceIp.ipv4.value
    }
} catch { $currentDSIP = $null }

if ($currentDSIP) {
    Write-Ok "Current Data Service IP : $currentDSIP"
}
else {
    Write-Warn "Data Service IP is not currently configured on this cluster."
}
Write-Detail "ETag : $etag"
Write-Host ""

# .NET HttpClient requires If-Match values to be RFC 7232 quoted-strings: "<value>"
# Wrap in double quotes if not already quoted
$etagForHeader = if ($etag -match '^".*"$' -or $etag -eq '*') { $etag } else { '"' + $etag + '"' }

#region ── Step 5: Build minimal PUT body ────────────────────────────────────

# The v4.2 PUT endpoint requires the full cluster object. We start from what
# the GET returned (data property) and update only the externalDataServiceIp.

$putBody = if ($clusterObj.data) { $clusterObj.data } else { $clusterObj }

# Remove fields that the v4 update API rejects as read-only or unsupported.
# 'faultToleranceState' triggers "desired cft policy not supported in cluster update"
# on single-node clusters. 'redundancyFactor' and 'buildInfo' are also read-only.
if ($putBody.PSObject.Properties['config'] -and $putBody.config) {
    foreach ($field in @('faultToleranceState', 'redundancyFactor', 'buildInfo', 'clusterArch')) {
        if ($putBody.config.PSObject.Properties[$field]) {
            $putBody.config.PSObject.Properties.Remove($field)
        }
    }
}

# Ensure network object exists
if (-not $putBody.network) {
    $putBody | Add-Member -MemberType NoteProperty -Name 'network' -Value ([PSCustomObject]@{})
}

# Build the externalDataServiceIp structure with the v4 API discriminator fields
# that Nutanix requires. Omitting $objectType/$reserved causes LEGACY_ERROR on PUT.
$newDSIP = [PSCustomObject]@{
    '$reserved'   = [PSCustomObject]@{ '$fv' = 'v1.r0' }
    '$objectType' = 'common.v1.config.IPAddress'
    ipv4          = [PSCustomObject]@{
        '$reserved'   = [PSCustomObject]@{ '$fv' = 'v1.r0' }
        '$objectType' = 'common.v1.config.IPv4Address'
        value         = $DataServiceIP
        prefixLength  = 32
    }
}

# Set or overwrite the field
if ($putBody.network.PSObject.Properties['externalDataServiceIp']) {
    $putBody.network.externalDataServiceIp = $newDSIP
}
else {
    $putBody.network | Add-Member -MemberType NoteProperty -Name 'externalDataServiceIp' -Value $newDSIP
}

$putBodyJson = $putBody | ConvertTo-Json -Depth 20

#endregion

#region ── Step 6: DryRun or PUT ─────────────────────────────────────────────

if ($DryRun) {
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  DRY-RUN MODE — No changes will be made                      " -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Would PUT to : $clusterUrl" -ForegroundColor White
  Write-Host "  If-Match     : $etagForHeader" -ForegroundColor White
    Write-Host ""
    Write-Host "  Relevant section of request body:" -ForegroundColor White
    Write-Host ($putBody.network | ConvertTo-Json -Depth 5) -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Remove -DryRun to apply the change." -ForegroundColor Yellow
    exit 0
}

Write-Step "Applying Data Service IP $DataServiceIP to cluster '$ClusterName'..."

# Nutanix v4 API requires the raw unquoted ETag in If-Match, but .NET's HttpClient
# enforces RFC 7232 and rejects unquoted values via the normal Headers dictionary.
# Solution: use HttpClient.TryAddWithoutValidation() to bypass schema validation.
$putResponse = $null
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.ServerCertificateCustomValidationCallback =
    [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
$httpClient = [System.Net.Http.HttpClient]::new($handler)

try {
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Put, $clusterUrl
    )
    $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($putBodyJson)
    $request.Content = [System.Net.Http.ByteArrayContent]::new($contentBytes)
    $request.Content.Headers.ContentType = `
        [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')

    $request.Headers.TryAddWithoutValidation('Authorization', "Basic $base64Creds") | Out-Null
    $request.Headers.TryAddWithoutValidation('Accept',        'application/json')    | Out-Null
    $request.Headers.TryAddWithoutValidation('If-Match',      $etag)                | Out-Null

    $httpResp        = $httpClient.SendAsync($request).GetAwaiter().GetResult()
    $responseContent = $httpResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    if (-not $httpResp.IsSuccessStatusCode) {
        $statusCode = [int]$httpResp.StatusCode
        $errDetail  = $responseContent
        Write-Fail "PUT request failed (HTTP $statusCode):"
        Write-Host $errDetail -ForegroundColor Gray
        if ($statusCode -eq 412) {
            Write-Warn "ETag mismatch — re-run the script to fetch a fresh ETag and retry."
        }
        exit 1
    }

    $putResponse = $responseContent | ConvertFrom-Json
}
catch {
    Write-Fail "PUT request failed: $_"
    exit 1
}
finally {
    $httpClient.Dispose()
}

# v4 async tasks return a taskExtId in the response
$taskId = $null
if ($putResponse -and $putResponse.PSObject.Properties['data'] -and
    $putResponse.data -and $putResponse.data.PSObject.Properties['extId']) {
    $taskId = $putResponse.data.extId
} elseif ($putResponse -and $putResponse.PSObject.Properties['taskExtId']) {
    $taskId = $putResponse.taskExtId
}

Write-Ok "PUT accepted by Prism Central."

if ($taskId) {
    Write-Detail "Task ID : $taskId"
    Write-Host ""

    # ── Poll task status ──────────────────────────────────────────────────────
    Write-Step "Waiting for task to complete..."

    $taskUrl  = "$PrismCentralUrl/api/prism/v4.0/config/tasks/$taskId"
    $deadline = (Get-Date).AddMinutes(5)
    $done     = $false

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        try {
            $taskResp  = Invoke-RestMethod -Uri $taskUrl -Method GET -Headers $headers -TimeoutSec 15
            $taskState = $taskResp.data.status
            Write-Detail "Task status : $taskState"

            if ($taskState -in @('SUCCEEDED', 'COMPLETED')) {
                $done = $true
                break
            }
            if ($taskState -in @('FAILED', 'ABORTED', 'CANCELED')) {
                Write-Fail "Task ended with status: $taskState"
                # Surface structured error messages
                if ($taskResp.data.PSObject.Properties['errorMessages'] -and $taskResp.data.errorMessages) {
                    $taskResp.data.errorMessages | ForEach-Object { Write-Detail ($_ | ConvertTo-Json -Compress) }
                }
                # Surface legacyErrorMessage which contains the real reason
                if ($taskResp.data.PSObject.Properties['legacyErrorMessage'] -and $taskResp.data.legacyErrorMessage) {
                    Write-Fail "Legacy error: $($taskResp.data.legacyErrorMessage)"
                }
                # Dump the full task data so nothing is hidden
                Write-Host "Full task response:" -ForegroundColor Yellow
                Write-Host ($taskResp.data | ConvertTo-Json -Depth 5) -ForegroundColor Gray
                exit 1
            }
        }
        catch {
            Write-Warn "Could not poll task status: $_"
        }
    }

    if (-not $done) {
        Write-Warn "Task did not complete within 5 minutes. Check Prism Central task list."
        Write-Detail "Task ID: $taskId"
    }
    else {
        Write-Ok "Task completed successfully."
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Data Service IP updated successfully                         " -ForegroundColor Green
Write-Host "  Cluster  : $ClusterName"                                       -ForegroundColor Green
Write-Host "  New DSIP : $DataServiceIP"                                      -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""

#endregion
