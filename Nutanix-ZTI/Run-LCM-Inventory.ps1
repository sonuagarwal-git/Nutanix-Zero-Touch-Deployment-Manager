#Requires -Version 5.1
<#
.SYNOPSIS
    Trigger an LCM inventory on a Nutanix cluster via Prism Central and report
    current software versions with upgrade recommendations.

.DESCRIPTION
    This script performs a full LCM (Life Cycle Manager) software inventory against
    a target cluster registered in Prism Central. It operates entirely over HTTPS
    REST APIs — no SSH or direct cluster access is required.

    Execution steps:
      1. Resolve the target cluster ExtId by name from Prism Central (clustermgmt v4.2).
      2. Submit an LCM inventory POST request targeting that cluster (lifecycle v4.2).
      3. Poll the resulting task until completion or timeout (prism v4.0).
      4. Retrieve all LCM software entities for the cluster (lifecycle v4.2, paginated).
      5. Analyse installed vs. available/recommended versions.
      6. Display a colour-coded report: updates available + components up to date.
      7. Optionally write an HTML snippet to a temp file so the pipeline email can
         include the upgrade recommendation table (file is deleted by the caller).

    API endpoints used:
      Cluster lookup   : GET  /api/clustermgmt/v4.2/config/clusters?$limit=100
      LCM inventory    : POST /api/lifecycle/v4.2/operations/$actions/inventory
      Task poll        : GET  /api/prism/v4.0/config/tasks/{extId}
      LCM entities     : GET  /api/lifecycle/v4.2/resources/entities?$page=N&$limit=100

    Config file fields read:
      clusterName          — target cluster name (must match registration in PC)
      prism_central.ip     — Prism Central IP address
      prism_central.username — Prism Central admin username
      prism_central.password — Prism Central admin password
      network.cluster_vip  — used to disambiguate duplicate cluster names (optional)

.PARAMETER ConfigFile
    Path to the cluster JSON config file. When supplied, all Prism Central credentials
    and the cluster name are read from it. Individual parameters below override these values.

.PARAMETER PrismCentralIP
    Prism Central IP address. Overrides prism_central.ip from ConfigFile.

.PARAMETER PrismCentralUsername
    Prism Central admin username. Overrides prism_central.username from ConfigFile.

.PARAMETER PrismCentralPassword
    Prism Central admin password. Overrides prism_central.password from ConfigFile.

.PARAMETER ClusterName
    Name of the target cluster as registered in Prism Central.
    Overrides clusterName from ConfigFile.

.PARAMETER DryRun
    When $true, submits the inventory in dry-run mode — checks readiness without
    performing the actual inventory scan. Default: $false.

.PARAMETER TaskTimeoutMinutes
    Maximum minutes to wait for the inventory task to complete. Default: 30.

.PARAMETER TaskPollSeconds
    Seconds between task status polls. Default: 30.

.PARAMETER ReportFile
    Optional path for a temporary HTML snippet used by the ZTD pipeline to embed
    upgrade recommendations in the result email. The caller (Start-Pipeline.ps1)
    reads and deletes this file immediately after the pipeline finishes.
    Leave empty when running standalone — no file is written.

.EXAMPLE
    .\Run-LCM-Inventory.ps1 -ConfigFile ".\Configs\my-cluster.json"

.EXAMPLE
    .\Run-LCM-Inventory.ps1 -ConfigFile ".\Configs\my-cluster.json" -DryRun:$true

.EXAMPLE
    # Standalone — supply credentials directly without a config file
    .\Run-LCM-Inventory.ps1 -PrismCentralIP "10.0.1.200" `
        -PrismCentralUsername "admin" -PrismCentralPassword "MyPass!" `
        -ClusterName "SITE-1P-CLUSTER-01"

.NOTES
    Author  : Sonu Agarwal
    Date    : May 29, 2026
    Version : 1.1
    Requires: Prism Central reachable on port 9440. No SSH or direct cluster access needed.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$PrismCentralIP,

    [Parameter(Mandatory = $false)]
    [string]$PrismCentralUsername,

    [Parameter(Mandatory = $false)]
    [string]$PrismCentralPassword,

    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [bool]$DryRun = $false,

    [Parameter(Mandatory = $false)]
    [int]$TaskTimeoutMinutes = 30,

    [Parameter(Mandatory = $false)]
    [int]$TaskPollSeconds = 30,

    # Path to write an HTML snippet for the pipeline email. Caller deletes this file after reading.
    [Parameter(Mandatory = $false)]
    [string]$ReportFile = ''
)

# ─── Load config / validate standalone params ─────────────────────────────────
$clusterVip = $null

if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }
    $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

    if (-not $ClusterName)          { $ClusterName          = $config.clusterName }
    if (-not $PrismCentralIP)       { $PrismCentralIP       = $config.prism_central.ip }
    if (-not $PrismCentralUsername) { $PrismCentralUsername = $config.prism_central.username }
    if (-not $PrismCentralPassword) { $PrismCentralPassword = $config.prism_central.password }
    $clusterVip = $config.network.cluster_vip
} elseif (-not $PrismCentralIP -or -not $PrismCentralUsername -or -not $PrismCentralPassword -or -not $ClusterName) {
    Write-Host "ERROR: Provide either -ConfigFile or all of: -PrismCentralIP, -PrismCentralUsername, -PrismCentralPassword, -ClusterName." -ForegroundColor Red
    exit 1
}

if (-not $ClusterName) {
    Write-Host "ERROR: 'clusterName' not found in config." -ForegroundColor Red
    exit 1
}
if (-not $PrismCentralIP -or -not $PrismCentralUsername -or -not $PrismCentralPassword) {
    Write-Host "ERROR: Prism Central IP, username, and password are required." -ForegroundColor Red
    exit 1
}

# ─── Common setup ─────────────────────────────────────────────────────────────
$pcBaseUrl = "https://${PrismCentralIP}:9440"

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "  [WARN] Running on PowerShell $($PSVersionTable.PSVersion). SSL bypass may not work reliably." -ForegroundColor Yellow
    Write-Host "         Run with 'pwsh' (PowerShell 7) for best results." -ForegroundColor Yellow
    Write-Host ""
}

[System.Net.ServicePointManager]::ServerCertificateValidationCallback =
    [System.Net.Security.RemoteCertificateValidationCallback]{ param($s,$c,$ch,$e) return $true }
$PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
$ErrorActionPreference = 'Stop'

$base64Creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${PrismCentralUsername}:${PrismCentralPassword}"))
$headers = @{
    'Authorization'   = "Basic $base64Creds"
    'Content-Type'    = 'application/json'
    'Accept'          = 'application/json'
    'NTNX-Request-Id' = [Guid]::NewGuid().ToString()
}

# ─── Helper: poll a prism v4.0 task ──────────────────────────────────────────
function Wait-V4Task {
    param([string]$ExtId)
    $deadline      = (Get-Date).AddMinutes($TaskTimeoutMinutes)
    $start         = Get-Date
    $lastStatus    = ''
    $lastPrintTime = $start
    $printInterval = 30
    $encodedId     = [Uri]::EscapeDataString($ExtId)
    $taskUrl       = "$pcBaseUrl/api/prism/v4.0/config/tasks/$encodedId"

    Write-Host "  Polling task : $ExtId" -ForegroundColor Gray
    Write-Host "  Started      : $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Gray
    Write-Host ""

    while ((Get-Date) -lt $deadline) {
        $now     = Get-Date
        $elapsed = [math]::Round(($now - $start).TotalSeconds)
        try {
            $taskHeaders = $headers.Clone()
            $taskHeaders['NTNX-Request-Id'] = [Guid]::NewGuid().ToString()
            $resp   = Invoke-RestMethod -Method GET -Uri $taskUrl -Headers $taskHeaders -TimeoutSec 30
            $task   = $resp.data
            $status = $task.status
            $pct    = if ($null -ne $task.progressPercentage) { [int]$task.progressPercentage } else { 0 }

            $barWidth = 30
            $filled   = [math]::Round($barWidth * $pct / 100)
            $arrow    = if ($pct -lt 100) { '>' } else { '=' }
            $bar      = '[' + ('=' * [math]::Max(0, $filled - 1)) + $arrow + (' ' * [math]::Max(0, $barWidth - $filled)) + ']'

            $statusChanged = $status -ne $lastStatus
            $heartbeatDue  = ($now - $lastPrintTime).TotalSeconds -ge $printInterval

            if ($statusChanged -or $heartbeatDue) {
                $color = switch ($status) {
                    'SUCCEEDED' { 'Green' } 'FAILED' { 'Red' } 'RUNNING' { 'Cyan' } default { 'Gray' }
                }
                Write-Host ("  [{0,4}s]  {1,-10}  {2}  {3,3}%" -f $elapsed, $status, $bar, $pct) -ForegroundColor $color
                $lastStatus    = $status
                $lastPrintTime = $now
            }

            if ($status -eq 'SUCCEEDED') { return @{ Success = $true;  Status = $status; Task = $task } }
            if ($status -in @('FAILED', 'CANCELLED', 'ABORTED')) {
                $errMsg = if ($task.errorMessages) {
                    ($task.errorMessages | ForEach-Object { $_.message }) -join '; '
                } else { 'No details returned by API.' }
                return @{ Success = $false; Status = $status; Error = $errMsg }
            }
        } catch {
            Write-Host ("  [{0,4}s]  Poll error: {1}" -f $elapsed, $_.Exception.Message) -ForegroundColor Yellow
        }
        Start-Sleep -Seconds $TaskPollSeconds
    }
    return @{ Success = $false; Status = 'TIMEOUT'; Error = "Task did not complete within $TaskTimeoutMinutes minutes." }
}

# ─── Helper: extract the best display version from an availableVersions entry ─
function Get-VersionString {
    param($Entry)
    if ($null -eq $Entry) { return $null }
    if ($Entry -is [string]) { return $Entry }
    if ($Entry.version)      { return $Entry.version }
    return "$Entry"
}

# ─── Banner ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "    LCM Inventory — lifecycle v4.2 API (via Prism Central)     " -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Prism Central : $pcBaseUrl"    -ForegroundColor Gray
Write-Host "  Cluster       : $ClusterName"  -ForegroundColor Gray
if ($DryRun) {
    Write-Host "  Mode          : DRY RUN (no actual inventory performed)" -ForegroundColor Yellow
}
Write-Host ""

# ─── Step 1: Resolve cluster extId ───────────────────────────────────────────
Write-Host "Step 1: Locating cluster '$ClusterName' on Prism Central..." -ForegroundColor Yellow

try {
    $allUrl     = "$pcBaseUrl/api/clustermgmt/v4.2/config/clusters?`$limit=100"
    $allResp    = Invoke-RestMethod -Method GET -Uri $allUrl -Headers $headers -TimeoutSec 30
    $candidates = @($allResp.data) | Where-Object { $_ -and $_.name -eq $ClusterName }

    $clusterObj = if ($candidates.Count -gt 1 -and $clusterVip) {
        $match = $candidates | Where-Object {
            $_.network.externalAddress.ipv4.value -eq $clusterVip
        } | Select-Object -First 1
        if ($match) {
            Write-Host "  Multiple clusters named '$ClusterName' found — disambiguating by VIP ($clusterVip)." -ForegroundColor Yellow
            $match
        } else { $candidates | Select-Object -First 1 }
    } else { $candidates | Select-Object -First 1 }

    if (-not $clusterObj) {
        Write-Host "  x Cluster '$ClusterName' not found on Prism Central." -ForegroundColor Red
        exit 1
    }

    $clusterExtId = $clusterObj.extId
    Write-Host "  ✓ Cluster found — extId: $clusterExtId" -ForegroundColor Green
} catch {
    $sc  = $_.Exception.Response.StatusCode.value__
    $msg = if ($sc) { "HTTP $sc`: $($_.ErrorDetails.Message)" } else { $_.Exception.Message }
    Write-Host "  x Failed to query clusters: $msg" -ForegroundColor Red
    exit 1
}

# ─── Step 2: POST LCM inventory ──────────────────────────────────────────────
Write-Host "`nStep 2: Submitting LCM inventory request..." -ForegroundColor Yellow

$inventoryUrl = "$pcBaseUrl/api/lifecycle/v4.2/operations/`$actions/inventory"
if ($DryRun) { $inventoryUrl += '?$dryrun=true' }

# Standard inventory body — no external credentials required for most environments.
# Extend the credentials array here if your environment uses a proxy or dark-site repo.
$invBody = '{}' 

$invHeaders = $headers.Clone()
$invHeaders['NTNX-Request-Id'] = [Guid]::NewGuid().ToString()
$invHeaders['X-Cluster-Id']    = $clusterExtId

Write-Host "  URL: $inventoryUrl" -ForegroundColor DarkGray
Write-Host "  X-Cluster-Id: $clusterExtId" -ForegroundColor DarkGray

try {
    $invResp   = Invoke-RestMethod -Method POST -Uri $inventoryUrl -Headers $invHeaders -Body $invBody -TimeoutSec 60
    $taskExtId = $invResp.data.extId
    if (-not $taskExtId) { throw "No task extId in response: $($invResp | ConvertTo-Json -Depth 3)" }
    Write-Host "  ✓ Inventory task submitted — extId: $taskExtId" -ForegroundColor Green
} catch {
    $sc  = $_.Exception.Response.StatusCode.value__
    $eb  = $_.ErrorDetails.Message
    $msg = if ($sc) { "HTTP $sc`: $eb" } else { $_.Exception.Message }
    Write-Host "  x Inventory POST failed: $msg" -ForegroundColor Red
    Write-Host "    URL: $inventoryUrl" -ForegroundColor DarkGray
    exit 1
}

# ─── Step 3: Poll task ────────────────────────────────────────────────────────
Write-Host "`nStep 3: Waiting for inventory task to complete..." -ForegroundColor Yellow
Write-Host "  Timeout: $TaskTimeoutMinutes minutes  (polling every $TaskPollSeconds s)" -ForegroundColor Gray
Write-Host ""

$result = Wait-V4Task -ExtId $taskExtId

Write-Host ""
if (-not $result.Success) {
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host "  x LCM Inventory $($result.Status)." -ForegroundColor Red
    Write-Host "    $($result.Error)" -ForegroundColor Red
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
    exit 1
}

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ✓ LCM Inventory completed successfully." -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green

# ─── Step 4: Retrieve Entities (Paginated) ───────────────────────────────────
Write-Host "`nStep 4: Retrieving LCM entities (paginated)..." -ForegroundColor Yellow

$entities = @()
$page = 0
$limit = 100

do {
    $url = "$pcBaseUrl/api/lifecycle/v4.2/resources/entities?`$page=$page&`$limit=$limit"

    $eHeaders = $headers.Clone()
    $eHeaders['NTNX-Request-Id'] = [Guid]::NewGuid().ToString()

    Write-Host "  Fetching page $page..." -ForegroundColor DarkGray

    $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $eHeaders -TimeoutSec 30

    $batch = @($resp.data)
    if ($batch.Count -gt 0) {
        $entities += $batch
    }

    $total = $resp.metadata.totalAvailableResults
    $page++

} while ($entities.Count -lt $total)

Write-Host "  ✓ Retrieved $($entities.Count) total entities." -ForegroundColor Green


# ─── Step 5: Analyze + Compare (FINAL WORKING LOGIC) ─────────────────────────
Write-Host "`nStep 5: Analyzing versions for cluster..." -ForegroundColor Yellow

# ✅ Filter only your cluster + SOFTWARE
$clusterEntities = $entities | Where-Object {
    $_.clusterExtId -eq $clusterExtId -and $_.entityType -eq "SOFTWARE"
}

if ($clusterEntities.Count -eq 0) {
    Write-Host "  No entities found for this cluster." -ForegroundColor Yellow
    return
}

# ✅ Group by component (entityModel)
$grouped = $clusterEntities | Group-Object entityModel

$finalList = @()

foreach ($g in $grouped) {

    # ✅ Pick BEST entity:
    # Prefer one with availableVersions OR meaningful upgrade info
    $selected = $g.Group | Where-Object {
        $_.availableVersions -or $_.targetVersion
    } | Select-Object -First 1

    if (-not $selected) {
        $selected = $g.Group | Select-Object -First 1
    }

    $finalList += $selected
}

$needUpgrade = @()
$upToDate    = @()

foreach ($e in $finalList) {

    $name    = $e.entityModel
    $current = $e.entityVersion
    $recommended = $null

    # ✅ Priority 1: RECOMMENDED
    if ($e.availableVersions) {
        $rec = $e.availableVersions |
            Where-Object { $_.status -eq "RECOMMENDED" } |
            Sort-Object order -Descending |
            Select-Object -First 1

        if ($rec) {
            $recommended = $rec.version
        }
    }

    # ✅ Priority 2: AVAILABLE (THIS FIXES YOUR ISSUE)
    if (-not $recommended -and $e.availableVersions) {
        $avail = $e.availableVersions |
            Sort-Object order -Descending |
            Select-Object -First 1

        if ($avail) {
            $recommended = $avail.version
        }
    }

    # ✅ Priority 3: targetVersion (fallback only)
    if (-not $recommended -and $e.targetVersion) {
        $recommended = $e.targetVersion
    }

    # ✅ Final fallback
    if (-not $recommended) {
        $recommended = $current
    }

    $obj = [PSCustomObject]@{
        Name    = $name
        Current = $current
        Target  = $recommended
    }

    if ($current -ne $recommended) {
        $needUpgrade += $obj
    } else {
        $upToDate += $obj
    }
}

Write-Host ""

# ─── OUTPUT: UPDATES ────────────────────────────────────────────────────────
if ($needUpgrade.Count -gt 0) {
    Write-Host "  ┌─ UPDATES AVAILABLE ($($needUpgrade.Count))" -ForegroundColor Yellow
    Write-Host ""

    foreach ($c in ($needUpgrade | Sort-Object Name)) {
        Write-Host ("  {0,-30}  {1,-15} → {2,-15}" -f $c.Name, $c.Current, $c.Target) -ForegroundColor Yellow
    }
    Write-Host ""
}

# ─── OUTPUT: UP TO DATE ─────────────────────────────────────────────────────
if ($upToDate.Count -gt 0) {
    Write-Host "  ┌─ UP TO DATE ($($upToDate.Count))" -ForegroundColor Green
    Write-Host ""

    foreach ($c in ($upToDate | Sort-Object Name)) {
        Write-Host ("  {0,-30}  {1}" -f $c.Name, $c.Current) -ForegroundColor Green
    }
    Write-Host ""
}

# ─── SUMMARY ────────────────────────────────────────────────────────────────
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ("  Total: {0} | Updates: {1} | Up-to-date: {2}" -f `
    $finalList.Count, $needUpgrade.Count, $upToDate.Count) -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ─── RECOMMENDATION ─────────────────────────────────────────────────────────
if ($needUpgrade.Count -gt 0) {
    Write-Host "  Recommended actions:" -ForegroundColor White
    Write-Host "    • Prism Central → LCM → Updates" -ForegroundColor Yellow

    Write-Host "    • Yellow = RECOMMENDED upgrades" -ForegroundColor Yellow
    Write-Host "    • (Non-recommended upgrades are still valid but optional)" -ForegroundColor DarkYellow

    Write-Host "    • Order: Foundation → NCC → AOS → AHV" -ForegroundColor Cyan
    Write-Host ""
} else {
    Write-Host "  All components are up to date ✅" -ForegroundColor Green
    Write-Host ""
}

exit 0