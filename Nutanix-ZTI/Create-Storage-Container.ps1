<#
.SYNOPSIS
    Create a Storage Container on a Nutanix cluster via Prism Central REST API v4.
.DESCRIPTION
    Uses the Nutanix storage v4.0 REST API via Prism Central to create a storage container.
    Config file is the primary input; all values can also be supplied via individual parameters.
    The cluster is located by name via clustermgmt v4.2, then the container is created
    and scoped to that cluster. Task completion is polled via prism v4.0 tasks API.

    API endpoints used:
      Cluster lookup : GET  /api/clustermgmt/v4.2/config/clusters?$filter=name eq '<name>'
      List/Check     : GET  /api/storage/v4.0.a3/config/storage-containers?$filter=clusterExtId eq '<id>'
      Create         : POST /api/storage/v4.0.a3/config/storage-containers
      Task poll      : GET  /api/prism/v4.0/config/tasks/{extId}

.PARAMETER ConfigFile
    Path to the cluster JSON config file. Optional when individual parameters are supplied.

.PARAMETER PrismCentralIP
    Prism Central IP address. Overrides the value from ConfigFile if both are provided.

.PARAMETER PrismCentralUsername
    Prism Central admin username.

.PARAMETER PrismCentralPassword
    Prism Central admin password.

.PARAMETER ClusterName
    Name of the target cluster as registered in Prism Central.

.PARAMETER ContainerName
    Storage container name. Defaults to the value in ConfigFile, or 'Workload-Container'.

.PARAMETER EnableCompression
    Enable compression on the storage container. Default: enabled.

.PARAMETER EnableDeduplication
    Enable post-process deduplication. Default: disabled.

.PARAMETER ReplicationFactor
    Replication factor (1, 2, or 3). When using ConfigFile, if replication_factor is not set
    (or is empty), it is auto-derived from node count: RF1 for 1 node, RF2 for 2+ nodes.
    An explicit value in config or this parameter always takes precedence.

.EXAMPLE
    .\Create-Storage-Container.ps1 -ConfigFile ".\Configs\my-cluster.json"
.EXAMPLE
    .\Create-Storage-Container.ps1 -ConfigFile ".\Configs\my-cluster.json" -EnableCompression:$false
.EXAMPLE
    # Run without a config file — container name defaults to 'Workload-Container'
    .\Create-Storage-Container.ps1 -PrismCentralIP "10.0.1.200" -PrismCentralUsername "admin" `
        -PrismCentralPassword "MyPass!" -ClusterName "SITE-1P-CLUSTER-01"
.EXAMPLE
    # Run without a config file — specify a custom container name
    .\Create-Storage-Container.ps1 -PrismCentralIP "10.0.1.200" -PrismCentralUsername "admin" `
        -PrismCentralPassword "MyPass!" -ClusterName "SITE-1P-CLUSTER-01" -ContainerName "My-Storage-Container"
.EXAMPLE
    # Standalone with explicit RF (RF2 is default; use -ReplicationFactor 1 for single-node)
    .\Create-Storage-Container.ps1 -PrismCentralIP "10.0.1.200" -PrismCentralUsername "admin" `
        -PrismCentralPassword "MyPass!" -ClusterName "SITE-1P-CLUSTER-01" `
        -ContainerName "My-Storage-Container" -ReplicationFactor 2

.NOTES
    Author: Sonu Agarwal
    Date: Mar 20, 2026
    Version: 1.0
#>

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
    [string]$ContainerName = 'Workload-Container',

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

# ─── Load config or validate individual params ─────────────────────────────────
$clusterVip       = $null
$compressionType  = 'inline'   # default: inline compression
$compressionDelay = 0          # secs; 0 = inline, >0 = post-process
$dedupValue       = 'OFF'      # default: deduplication off

if ($ConfigFile) {
    $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    if (-not $ClusterName)          { $ClusterName          = $config.clusterName }
    if (-not $PrismCentralIP)       { $PrismCentralIP       = $config.prism_central.ip }
    if (-not $PrismCentralUsername) { $PrismCentralUsername = $config.prism_central.username }
    if (-not $PrismCentralPassword) { $PrismCentralPassword = $config.prism_central.password }

    $scCfg = $config.storage_container

    # Container name — prefer storage_container.name, fall back to legacy storage_container_name
    if (-not $PSBoundParameters.ContainsKey('ContainerName')) {
        $ContainerName = if ($scCfg -and $scCfg.name) { $scCfg.name }
                         elseif ($config.storage_container_name) { $config.storage_container_name }
                         else { 'Workload-Container' }
    }

    $clusterVip = $config.network.cluster_vip

    # Node count — used for RF validation and deduplication guardrails
    $nodeCount = if ($config.network.nodes) { @($config.network.nodes).Count } else { 3 }

    # Replication Factor — config value overrides default; explicit param wins all
    if (-not $PSBoundParameters.ContainsKey('ReplicationFactor')) {
        $cfgRF = if ($scCfg) { "$($scCfg.replication_factor)".Trim().ToLower() } else { '' }
        if ($cfgRF -match '^\d+$') {
            $ReplicationFactor = [int]$cfgRF
            Write-Host "  ℹ Replication Factor RF$ReplicationFactor from config." -ForegroundColor Cyan
        } else {
            # not set — default: RF1 for 1 node, RF2 for 2+ nodes
            $ReplicationFactor = if ($nodeCount -eq 1) { 1 } else { 2 }
            Write-Host "  ℹ $nodeCount node(s) detected — Replication Factor defaulted to RF$ReplicationFactor." -ForegroundColor Cyan
        }
    }

    # Guardrail: validate RF against minimum node requirements (RF1≥1, RF2≥2, RF3≥5)
    $rfMinNodes  = @{ 1 = 1; 2 = 2; 3 = 5 }
    $minRequired = $rfMinNodes[[int]$ReplicationFactor]
    if ($nodeCount -lt $minRequired) {
        $fallback = if ($nodeCount -eq 1) { 1 } else { 2 }
        Write-Host "  ⚠ Replication Factor guardrail triggered:" -ForegroundColor Yellow
        Write-Host "    Reason   : RF$ReplicationFactor requires a minimum of $minRequired node(s); this cluster has $nodeCount node(s)." -ForegroundColor Yellow
        Write-Host "    Fallback : RF$fallback applied (recommended default — RF1 for 1 node, RF2 for 2+ nodes)." -ForegroundColor Yellow
        $ReplicationFactor = $fallback
    }

    # Compression type
    if ($scCfg -and $scCfg.compression) {
        $compressionType = "$($scCfg.compression)".Trim().ToLower()
    }
    switch ($compressionType) {
        'none'         { $EnableCompression = $false; $compressionDelay = 0 }
        'post_process' {
            $EnableCompression = $true
            $delayMins = if ($scCfg.compression_delay_mins) { [int]$scCfg.compression_delay_mins } else { 60 }
            $compressionDelay  = $delayMins * 60   # convert to seconds for API
        }
        default        { $EnableCompression = $true; $compressionDelay = 0 }   # inline (default)
    }

    # Deduplication
    if ($scCfg -and $null -ne $scCfg.deduplication) {
        $dedupValue = if ($scCfg.deduplication -eq $true) { 'POST_PROCESS' } else { 'OFF' }
    }

    # Guardrail: Capacity Deduplication requires minimum 3 nodes
    if ($dedupValue -eq 'POST_PROCESS' -and $nodeCount -lt 3) {
        Write-Host "  ⚠ Capacity Deduplication guardrail triggered:" -ForegroundColor Yellow
        Write-Host "    Reason   : Capacity Deduplication requires a minimum of 3 nodes; this cluster has $nodeCount node(s)." -ForegroundColor Yellow
        Write-Host "    Fallback : Deduplication disabled (default — cannot be enabled on fewer than 3 nodes)." -ForegroundColor Yellow
        $dedupValue = 'OFF'
    }

} elseif (-not $PrismCentralIP -or -not $PrismCentralUsername -or -not $PrismCentralPassword -or -not $ClusterName) {
    Write-Host "ERROR: Provide either -ConfigFile or all of: -PrismCentralIP, -PrismCentralUsername, -PrismCentralPassword, -ClusterName." -ForegroundColor Red
    exit 1
}

if (-not $ClusterName) {
    Write-Host "ERROR: 'clusterName' not found in config file: $ConfigFile" -ForegroundColor Red
    exit 1
}

$pcBaseUrl   = "https://${PrismCentralIP}:9440"
$pcUsername  = $PrismCentralUsername
$pcPassword  = $PrismCentralPassword
$clusterName = $ClusterName

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

# ─── Step 2: Check if workload container already exists ────────────────────────────────────────
Write-Host "`nStep 2: Checking existing storage containers on cluster..." -ForegroundColor Yellow

$allContainers = @()
try {
    $encodedFilter = [Uri]::EscapeDataString("clusterExtId eq '$clusterExtId'")
    $listResult    = Invoke-RestMethod -Uri "$pcBaseUrl/api/storage/v4.0.a3/config/storage-containers?`$filter=$encodedFilter&`$limit=50" `
                         -Method GET -Headers $storageHeaders -ErrorAction Stop
    $allContainers = @($listResult.data | Where-Object { $_ })
    Write-Host "  Found $($allContainers.Count) container(s) on cluster." -ForegroundColor Gray
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    Write-Host "  ⚠ Could not list containers (HTTP $statusCode) — will attempt creation." -ForegroundColor Yellow
}

$existing = $allContainers | Where-Object { $_.name -eq $ContainerName } | Select-Object -First 1

if ($existing) {
    Write-Host "  ⚠ Container '$ContainerName' already exists — skipping creation." -ForegroundColor Yellow
    Write-Host "    To change compression or deduplication settings, update the container manually in Prism." -ForegroundColor Yellow
    exit 0
}
Write-Host "  ✓ Container '$ContainerName' does not exist — will create." -ForegroundColor Green

$compressionLabel = switch ($compressionType) {
    'none'         { 'Disabled' }
    'post_process' { "Post-Process (delay: $($compressionDelay / 60) min)" }
    default        { 'Inline' }
}

# ─── Step 3: Create the storage container ─────────────────────────────────────
Write-Host "`nStep 3: Creating storage container '$ContainerName'..." -ForegroundColor Yellow

Write-Host ""
Write-Host "  Container Configuration:" -ForegroundColor Gray
Write-Host "    Name                : $ContainerName"                                                        -ForegroundColor Cyan
Write-Host "    Cluster ExtId       : $clusterExtId"                                                        -ForegroundColor Cyan
Write-Host "    Replication Factor  : RF$ReplicationFactor"                                                  -ForegroundColor Cyan
Write-Host "    Compression         : $compressionLabel"                                                     -ForegroundColor Cyan
Write-Host "    Deduplication       : $(if ($dedupValue -eq 'POST_PROCESS') { 'Enabled' } else { 'Disabled' })" -ForegroundColor Cyan
Write-Host ""

$body = @{
    name                  = $ContainerName
    replicationFactor     = $ReplicationFactor
    isCompressionEnabled  = [bool]$EnableCompression
    compressionDelaySecs  = $compressionDelay
    onDiskDedup           = $dedupValue
} | ConvertTo-Json
Write-Host "  Request body: $body" -ForegroundColor Gray

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
    $listResult    = Invoke-RestMethod -Uri "$pcBaseUrl/api/storage/v4.0.a3/config/storage-containers?`$filter=$encodedFilter&`$limit=50" `
                         -Method GET -Headers $storageHeaders -ErrorAction Stop
    $created       = @($listResult.data) | Where-Object { $_ -and $_.name -eq $ContainerName } | Select-Object -First 1
    if ($created) {
        $verExtId = if ($created.containerExtId) { $created.containerExtId } elseif ($created.extId) { $created.extId } else { 'N/A' }
        Write-Host "  ✓ Storage container is active and ready!" -ForegroundColor Green
        Write-Host "    Name                : $($created.name)"                                                           -ForegroundColor Cyan
        Write-Host "    ExtId               : $verExtId"                                                                  -ForegroundColor Cyan
        Write-Host "    Replication Factor  : RF$ReplicationFactor"                                                       -ForegroundColor Cyan
        Write-Host "    Compression         : $compressionLabel"                                                          -ForegroundColor Cyan
        Write-Host "    Deduplication       : $(if ($dedupValue -eq 'POST_PROCESS') { 'Enabled' } else { 'Disabled' })"  -ForegroundColor Cyan
    } else {
        Write-Host "  ⚠ Container not found in list — may still be provisioning." -ForegroundColor Yellow
    }
} catch {
    Write-Host "  ⚠ Could not verify container (likely created successfully)." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✓ Done." -ForegroundColor Green
exit 0
