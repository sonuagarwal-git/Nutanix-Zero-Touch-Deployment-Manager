<#
.SYNOPSIS
    Create a Storage Container on a Nutanix cluster via Prism Central REST API v4.
.DESCRIPTION
    Uses the Nutanix storage v4.0 REST API via Prism Central to create a storage container.
    All credentials are read from the config file (prism_central section).
    The cluster is located by name via clustermgmt v4.2, then the container is created
    and scoped to that cluster. Task completion is polled via prism v4.0 tasks API.

    API endpoints used:
      Cluster lookup : GET  /api/clustermgmt/v4.2/config/clusters?$filter=name eq '<name>'
      List/Check     : GET  /api/storage/v4.0.a3/config/storage-containers?$filter=clusterExtId eq '<id>'
      Create         : POST /api/storage/v4.0.a3/config/storage-containers
      Task poll      : GET  /api/prism/v4.0/config/tasks/{extId}

.EXAMPLE
    .\Create-Nutanix-Storage-Container.ps1 -ConfigFile ".\Configs\DKLAB-1-Create.json"
.EXAMPLE
    .\Create-Nutanix-Storage-Container.ps1 -ConfigFile ".\Configs\DKLAB-1-Create.json" -EnableCompression:$false -ReplicationFactor 3
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [switch]$EnableCompression = $true,

    [Parameter(Mandatory = $false)]
    [switch]$EnableDeduplication = $false,

    [Parameter(Mandatory = $false)]
    [int]$ReplicationFactor = 2,

    [Parameter(Mandatory = $false)]
    [switch]$SkipExistingCheck = $false,

    [Parameter(Mandatory = $false)]
    [int]$TaskTimeoutMinutes = 10,

    [Parameter(Mandatory = $false)]
    [int]$TaskPollSeconds = 5
)

# ─── Load config ──────────────────────────────────────────────────────────────
$config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json

$clusterName = $config.clusterName
if (-not $clusterName) {
    Write-Host "ERROR: 'clusterName' not found in config file: $ConfigFile" -ForegroundColor Red
    exit 1
}

$pcSection = $config.prism_central
if (-not $pcSection) {
    Write-Host "ERROR: 'prism_central' section not found in config file: $ConfigFile" -ForegroundColor Red
    exit 1
}

$pcBaseUrl     = $pcSection.url.TrimEnd('/')
$pcUsername    = $pcSection.username
$pcPassword    = $pcSection.password
$clusterVip    = $config.network.cluster_vip
# Container name from config, defaulting to 'Workload-Container'
$ContainerName = if ($config.storage_container_name) { $config.storage_container_name } else { 'Workload-Container' }

# Derive replication factor from node count: 1 node = RF1, 2+ nodes = RF2
$nodeCount = if ($config.network.nodes) { @($config.network.nodes).Count } else { 3 }
$ReplicationFactor = if ($nodeCount -eq 1) { 1 } else { 2 }
Write-Host "  ℹ $nodeCount node(s) detected — Replication Factor set to $ReplicationFactor." -ForegroundColor Cyan

# SSL bypass for self-signed certs
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
$PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true

$base64Creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${pcUsername}:${pcPassword}"))
$requestId   = [Guid]::NewGuid().ToString()
$headers = @{
    'Authorization'   = "Basic $base64Creds"
    'Content-Type'    = 'application/json'
    'Accept'          = 'application/json'
    'NTNX-Request-Id' = $requestId
}

# ─── Helper: poll a prism v4.0 task to completion ─────────────────────────────
function Wait-V4Task {
    param([string]$ExtId)
    $deadline   = (Get-Date).AddMinutes($TaskTimeoutMinutes)
    $start      = Get-Date
    $lastStatus = ''
    $encodedId  = [Uri]::EscapeDataString($ExtId)
    $taskUrl    = "$pcBaseUrl/api/prism/v4.0/config/tasks/$encodedId"

    Write-Host "  Polling task: $ExtId" -ForegroundColor Gray

    while ((Get-Date) -lt $deadline) {
        $elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds)
        try {
            $resp   = Invoke-RestMethod -Method GET -Uri $taskUrl -Headers $headers -TimeoutSec 30
            $task   = $resp.data
            $status = $task.status
            $pct    = if ($null -ne $task.progressPercentage) { [int]$task.progressPercentage } else { 0 }

            if ($status -ne $lastStatus) {
                $color = switch ($status) {
                    'SUCCEEDED' { 'Green' } 'FAILED' { 'Red' } 'RUNNING' { 'White' } default { 'Gray' }
                }
                Write-Host ("  [{0,4}s] {1,9}  {2,3}%" -f $elapsed, $status, $pct) -ForegroundColor $color
                $lastStatus = $status
            }

            if ($status -eq 'SUCCEEDED') { return @{ Success = $true; Status = $status } }
            if ($status -in @('FAILED', 'CANCELLED', 'ABORTED')) {
                $errMsg = if ($task.errorMessages) {
                    ($task.errorMessages | ForEach-Object { $_.message }) -join '; '
                } else { 'No details returned' }
                return @{ Success = $false; Status = $status; Error = $errMsg }
            }
        } catch {
            Write-Host ("  [{0,4}s] Poll error: {1}" -f $elapsed, $_.Exception.Message) -ForegroundColor Yellow
        }
        Start-Sleep -Seconds $TaskPollSeconds
    }
    return @{ Success = $false; Status = 'TIMEOUT'; Error = "Task did not complete within $TaskTimeoutMinutes minutes" }
}

# ─── Banner ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "    Create Storage Container — storage v4.0.a3 API (via PC)     " -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Prism Central  : $pcBaseUrl"  -ForegroundColor Gray
Write-Host "  Cluster Name   : $clusterName" -ForegroundColor Gray
Write-Host "  Container Name : $ContainerName" -ForegroundColor Gray

# ─── Step 1: Resolve cluster extId from PC ────────────────────────────────────
Write-Host "`nStep 1: Locating cluster '$clusterName' on Prism Central..." -ForegroundColor Yellow

$encodedName = [Uri]::EscapeDataString("name eq '$clusterName'")
$clusterUrl  = "$pcBaseUrl/api/clustermgmt/v4.2/config/clusters?`$filter=$encodedName"

try {
    # Always list all clusters and filter manually — avoids stale-registration false match
    $allUrl     = "$pcBaseUrl/api/clustermgmt/v4.2/config/clusters?`$limit=100"
    $allResp    = Invoke-RestMethod -Method GET -Uri $allUrl -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    $candidates = @($allResp.data) | Where-Object { $_ -and $_.name -eq $clusterName }

    # Disambiguate stale registrations by VIP
    $clusterObj = if ($candidates.Count -gt 1 -and $clusterVip) {
        $vipMatch = $candidates | Where-Object {
            $_.network.externalAddress.ipv4.value -eq $clusterVip
        } | Select-Object -First 1
        if ($vipMatch) {
            Write-Host "  Multiple clusters named '$clusterName' — selected by VIP ($clusterVip)." -ForegroundColor Yellow
            $vipMatch
        } else {
            $candidates | Select-Object -First 1
        }
    } else {
        $candidates | Select-Object -First 1
    }

    if (-not $clusterObj) {
        Write-Host "  ✗ Cluster '$clusterName' not found on Prism Central." -ForegroundColor Red
        exit 1
    }
    $clusterExtId = $clusterObj.extId
    Write-Host "  ✓ Cluster found — extId: $clusterExtId" -ForegroundColor Green
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $errBody    = $_.ErrorDetails.Message
    Write-Host "  ✗ Failed to query clusters (HTTP $statusCode): $errBody" -ForegroundColor Red
    exit 1
}

# Storage API requires X-Cluster-Id header to scope operations to the target cluster
$storageHeaders = $headers.Clone()
$storageHeaders['X-Cluster-Id'] = $clusterExtId

# ─── Step 1b: Enable RF1 support on cluster if this is a 1-node deployment ───────────────
if ($ReplicationFactor -eq 1) {
    Write-Host "`nStep 1b: Enabling RF1 container support via Prism Central..." -ForegroundColor Yellow
    try {
        # GET cluster detail — use Invoke-RestMethod with -ResponseHeadersVariable so we
        # get the ETag without needing Invoke-WebRequest (which has separate SSL handling).
        $rf1GetHeaders = $headers.Clone()
        $rf1GetHeaders['NTNX-Request-Id'] = [Guid]::NewGuid().ToString()
        $clusterDetailUrl = "$pcBaseUrl/api/clustermgmt/v4.2/config/clusters/$clusterExtId"

        $respHeaders = $null
        $clusterDetail = Invoke-RestMethod -Method GET -Uri $clusterDetailUrl `
                             -Headers $rf1GetHeaders -ResponseHeadersVariable 'respHeaders' `
                             -TimeoutSec 30 -ErrorAction Stop
        $etag      = if ($respHeaders -and $respHeaders['ETag']) { $respHeaders['ETag'] | Select-Object -First 1 } else { $null }
        $clusterData = $clusterDetail.data

        # Set the RF1 data path redundancy flag in the cluster config object
        if ($null -ne $clusterData.config) {
            $clusterData.config | Add-Member -MemberType NoteProperty `
                -Name 'enableRfOneDataPathRedundancy' -Value $true -Force
        }

        $putHeaders = $headers.Clone()
        $putHeaders['NTNX-Request-Id'] = [Guid]::NewGuid().ToString()
        if ($etag) { $putHeaders['If-Match'] = $etag }

        # Body is the cluster object directly — NOT wrapped in { data: ... }
        $putBody = $clusterData | ConvertTo-Json -Depth 20 -Compress
        $putResp = Invoke-RestMethod -Method PUT -Uri $clusterDetailUrl `
                       -Headers $putHeaders -Body $putBody -TimeoutSec 30 -ErrorAction Stop

        # PUT may return a task extId
        $rf1TaskId = $putResp.data.extId
        if ($rf1TaskId) {
            Write-Host "  Waiting for cluster update task to complete..." -ForegroundColor Cyan
            $rf1Result = Wait-V4Task -ExtId $rf1TaskId
            if ($rf1Result.Success) {
                Write-Host "  ✓ RF1 support enabled on cluster." -ForegroundColor Green
            } else {
                Write-Host "  ⚠ Cluster update task ended with '$($rf1Result.Status)': $($rf1Result.Error)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  ✓ RF1 support enabled on cluster." -ForegroundColor Green
        }
        Start-Sleep -Seconds 3
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errBody    = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Host "  ⚠ Could not enable RF1 via PC (HTTP $statusCode): $errBody" -ForegroundColor Yellow
        Write-Host "  Attempting container creation with RF1 anyway..." -ForegroundColor Yellow
    }
}

# ─── Step 2: List all containers, delete default-container, skip if workload-container exists ──
Write-Host "`nStep 2: Checking existing storage containers on cluster..." -ForegroundColor Yellow

$allContainers = @()
try {
    $encodedFilter = [Uri]::EscapeDataString("clusterExtId eq '$clusterExtId'")
    $listResult    = Invoke-RestMethod -Uri "$pcBaseUrl/api/storage/v4.0.a3/config/storage-containers?`$filter=$encodedFilter&`$limit=100" `
                         -Method GET -Headers $storageHeaders -ErrorAction Stop
    $allContainers = @($listResult.data | Where-Object { $_ })
    Write-Host "  Found $($allContainers.Count) container(s) on cluster." -ForegroundColor Gray
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    Write-Host "  ⚠ Could not list containers (HTTP $statusCode) — will attempt creation." -ForegroundColor Yellow
}

# Delete default-container if it exists
$defaultContainer = $allContainers | Where-Object { $_.name -eq 'default-container' }
if ($defaultContainer) {
    Write-Host "  Found 'default-container' — deleting..." -ForegroundColor Cyan
    try {
        # URL-encode the extId — Nutanix container extIds can contain colons or other special chars
        $encodedCtrId = [Uri]::EscapeDataString($defaultContainer.extId)
        $deluri = "$pcBaseUrl/api/storage/v4.0.a3/config/storage-containers/$encodedCtrId?ignoreSmallFiles=true"
        $delResp = Invoke-RestMethod -Uri $deluri -Method DELETE -Headers $storageHeaders -ErrorAction Stop
        $delTaskId = $delResp.data.extId
        if ($delTaskId) {
            Write-Host "  Waiting for delete task to complete..." -ForegroundColor Cyan
            $delResult = Wait-V4Task -ExtId $delTaskId
            if ($delResult.Success) {
                Write-Host "  ✓ 'default-container' deleted successfully." -ForegroundColor Green
            } else {
                Write-Host "  ⚠ Delete task ended with status '$($delResult.Status)': $($delResult.Error)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  ✓ 'default-container' deleted." -ForegroundColor Green
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errBody    = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Host "  ⚠ Could not delete 'default-container' (HTTP $statusCode): $errBody — continuing." -ForegroundColor Yellow
    }
} else {
    Write-Host "  'default-container' not present — nothing to delete." -ForegroundColor Gray
}

# Skip creation if workload-container already exists
$existing = $allContainers | Where-Object { $_.name -eq $ContainerName }
if ($existing) {
    Write-Host "  ⚠ Storage container '$ContainerName' already exists — nothing to do." -ForegroundColor Yellow
    exit 0
}
Write-Host "  ✓ Container '$ContainerName' does not exist — will create." -ForegroundColor Green

# ─── Step 3: Create the storage container ─────────────────────────────────────
Write-Host "`nStep 3: Creating storage container '$ContainerName' via storage v4.0.a3 API..." -ForegroundColor Yellow

$dedupValue = if ($EnableDeduplication) { 'POST_PROCESS' } else { 'NONE' }

$body = @{
    name               = $ContainerName
    replicationFactor  = $ReplicationFactor
    compressionEnabled = [bool]$EnableCompression
    onDiskDedup        = $dedupValue
} | ConvertTo-Json

Write-Host ""
Write-Host "  Container Configuration:" -ForegroundColor Gray
Write-Host "    Name                : $ContainerName"                                                        -ForegroundColor White
Write-Host "    Cluster ExtId       : $clusterExtId"                                                        -ForegroundColor White
Write-Host "    Replication Factor  : $ReplicationFactor"                                                   -ForegroundColor White
Write-Host "    Compression         : $(if ($EnableCompression) { 'Enabled' } else { 'Disabled' })"        -ForegroundColor White
Write-Host "    Inline Deduplication: $(if ($EnableDeduplication) { 'Enabled' } else { 'Disabled' })"      -ForegroundColor White
Write-Host ""

try {
    $createResp = Invoke-RestMethod -Uri "$pcBaseUrl/api/storage/v4.0.a3/config/storage-containers" `
        -Method POST -Headers $storageHeaders -Body $body -ErrorAction Stop

    $taskExtId = $createResp.data.extId
    if (-not $taskExtId) {
        Write-Host "  ✓ Storage container '$ContainerName' created (synchronous response)." -ForegroundColor Green
    } else {
        Write-Host "  Task submitted. Waiting for completion..." -ForegroundColor Cyan
        $taskResult = Wait-V4Task -ExtId $taskExtId
        if (-not $taskResult.Success) {
            Write-Host "`n  ✗ Task $($taskResult.Status): $($taskResult.Error)" -ForegroundColor Red
            exit 1
        }
        Write-Host "  ✓ Storage container '$ContainerName' created successfully!" -ForegroundColor Green
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $errBody    = $_.ErrorDetails.Message
    Write-Host "`n  ✗ Failed to create storage container (HTTP $statusCode)!" -ForegroundColor Red
    Write-Host "  $errBody" -ForegroundColor Red
    exit 1
}

# ─── Step 4: Verify ───────────────────────────────────────────────────────────
Write-Host "`nStep 4: Verifying storage container..." -ForegroundColor Yellow
Start-Sleep -Seconds 3

try {
    $encodedFilter = [Uri]::EscapeDataString("clusterExtId eq '$clusterExtId'")
    $listResult    = Invoke-RestMethod -Uri "$pcBaseUrl/api/storage/v4.0.a3/config/storage-containers?`$filter=$encodedFilter&`$limit=100" `
                         -Method GET -Headers $storageHeaders -ErrorAction Stop
    $created       = @($listResult.data) | Where-Object { $_ -and $_.name -eq $ContainerName }
    if ($created) {
        Write-Host "  ✓ Storage container is active and ready!" -ForegroundColor Green
        Write-Host "    Name                : $($created.name)"               -ForegroundColor Cyan
        Write-Host "    ExtId               : $($created.extId)"              -ForegroundColor Cyan
        Write-Host "    Replication Factor  : $($created.replicationFactor)"  -ForegroundColor Cyan
        Write-Host "    Compression         : $($created.compressionEnabled)" -ForegroundColor Cyan
    } else {
        Write-Host "  ⚠ Container not found in list — may still be provisioning." -ForegroundColor Yellow
    }
} catch {
    Write-Host "  ⚠ Could not verify container (likely created successfully)." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✓ Done." -ForegroundColor Green
exit 0
