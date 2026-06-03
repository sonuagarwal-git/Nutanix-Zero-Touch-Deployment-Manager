<#
.SYNOPSIS
    Checks and sets the bond mode of a Nutanix virtual switch (vs0) to the mode
    specified by vswitch_mode in the deployment config (ACTIVE_BACKUP, BALANCE_TCP, or BALANCE_SLB).

.DESCRIPTION
    This script connects to Prism Central and:
    1. Resolves the cluster UUID from the cluster name.
    2. Retrieves the virtual switch configuration for that cluster.
    3. If bondMode already matches the target mode, reports success with no change.
    4. If not, issues a PUT call to change bondMode using isQuickMode
       to avoid a rolling maintenance-mode restart.
    5. Polls the resulting task until SUCCEEDED or FAILED.
    6. Verifies the bond mode was correctly applied.

.PARAMETER ConfigFile
    Path to the JSON deployment config file. Reads prism_central.ip, prism_central.username,
    prism_central.password and clusterName from it.

.PARAMETER PrismCentralIP
    Override the Prism Central IP from the config file.

.PARAMETER ClusterName
    Override the cluster name from the config file.

.PARAMETER Username
    Override the Prism Central username from the config file.

.PARAMETER Password
    Override the Prism Central password from the config file.

.PARAMETER Port
    Port for Prism Central API (default: 9440).

.PARAMETER TaskTimeoutMinutes
    Maximum time to wait for the bond-mode change task (default: 15 minutes).

.PARAMETER TaskPollSeconds
    Polling interval for task status checks (default: 15 seconds).

.EXAMPLE
    .\Set-Nutanx-VSwitch-BondMode.ps1 -ConfigFile .\Configs\my-cluster.json

.NOTES
    Author:  Sonu Agarwal
    Date:    May 29, 2026
    Version: 2.1 - Bond mode is now read from config vswitch_mode field instead of
                   hardcoded; supports ACTIVE_BACKUP, BALANCE_TCP, BALANCE_SLB.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$PrismCentralIP,

    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$Username,

    [Parameter(Mandatory = $false)]
    [string]$Password,

    [Parameter(Mandatory = $false)]
    [int]$Port = 9440,

    [Parameter(Mandatory = $false)]
    [int]$TaskTimeoutMinutes = 15,

    [Parameter(Mandatory = $false)]
    [int]$TaskPollSeconds = 15
)

# -- Load values from config file if provided --
if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) {
        Write-Error "Config file not found: $ConfigFile"
        exit 1
    }
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json

    if (-not $PrismCentralIP) { $PrismCentralIP = $cfg.prism_central.ip }
    if (-not $Username)       { $Username       = $cfg.prism_central.username }
    if (-not $Password)       { $Password       = $cfg.prism_central.password }
    if (-not $ClusterName)    { $ClusterName    = $cfg.clusterName }

    # Read vswitch_mode from config; default to ACTIVE_BACKUP if not set
    $validModes = @('ACTIVE_BACKUP', 'BALANCE_TCP', 'BALANCE_SLB')
    $cfgMode    = $cfg.vswitch_mode
    if ($cfgMode -and $validModes -contains $cfgMode) {
        $TargetBondMode = $cfgMode
    } else {
        if ($cfgMode) {
            Write-Warning "vswitch_mode '$cfgMode' is not valid. Valid values: $($validModes -join ', '). Defaulting to ACTIVE_BACKUP."
        }
        $TargetBondMode = 'ACTIVE_BACKUP'
    }
}

# -- Validate required values --
if (-not $PrismCentralIP) { Write-Error "PrismCentralIP is required (via -ConfigFile or -PrismCentralIP)."; exit 1 }
if (-not $ClusterName)    { Write-Error "ClusterName is required (via -ConfigFile or -ClusterName).";       exit 1 }
if (-not $Username)       { Write-Error "Username is required (via -ConfigFile or -Username).";             exit 1 }
if (-not $Password)       { Write-Error "Password is required (via -ConfigFile or -Password).";             exit 1 }

$BaseUrl = "https://${PrismCentralIP}:${Port}"

# If not set from config (no ConfigFile path), default to ACTIVE_BACKUP
if (-not $TargetBondMode) { $TargetBondMode = 'ACTIVE_BACKUP' }

# -- Auth header --
$credPair     = "${Username}:${Password}"
$encodedCreds = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($credPair))
$headers = @{
    "Authorization" = "Basic $encodedCreds"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
}

#region Logging
function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    $symbol = switch ($Level) {
        'Info'    { 'ℹ' }
        'Success' { '✓' }
        'Warning' { '⚠' }
        'Error'   { '✗' }
    }
    $color = switch ($Level) {
        'Info'    { 'Cyan'   }
        'Success' { 'Green'  }
        'Warning' { 'Yellow' }
        'Error'   { 'Red'    }
    }
    Write-Host "  $symbol $Message" -ForegroundColor $color
}
#endregion

#region Helper: Poll a Prism v4.0 task until SUCCEEDED / FAILED / timeout
function Wait-V4Task {
    param([string]$ExtId)
    $deadline = (Get-Date).AddMinutes($TaskTimeoutMinutes)
    $start    = Get-Date
    $taskUrl  = "$BaseUrl/api/prism/v4.0/config/tasks/$([Uri]::EscapeDataString($ExtId))"
    Write-LogMessage "Polling task $ExtId (timeout: ${TaskTimeoutMinutes}m, interval: ${TaskPollSeconds}s)" -Level Info
    while ((Get-Date) -lt $deadline) {
        $elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds)
        try {
            $taskHeaders = $headers.Clone()
            $taskHeaders['NTNX-Request-Id'] = [System.Guid]::NewGuid().ToString()
            $task   = (Invoke-RestMethod -Method GET -Uri $taskUrl -Headers $taskHeaders `
                       -SkipCertificateCheck -TimeoutSec 30).data
            $status = $task.status
            $pct    = if ($null -ne $task.progressPercentage) { [int]$task.progressPercentage } else { 0 }
            $color  = switch ($status) {
                'SUCCEEDED' { 'Green'  }
                'FAILED'    { 'Red'    }
                'RUNNING'   { 'White'  }
                'QUEUED'    { 'Yellow' }
                default     { 'Gray'   }
            }
            Write-Host ("    [{0,4}s] {1,-12} {2,3}%" -f $elapsed, $status, $pct) -ForegroundColor $color
            if ($status -eq 'SUCCEEDED') { return @{ Success = $true } }
            if ($status -in @('FAILED','CANCELLED','ABORTED')) {
                $errMsg = if ($task.errorMessages) {
                    ($task.errorMessages | ForEach-Object { $_.message }) -join '; '
                } else { 'No details returned by API' }
                return @{ Success = $false; Error = $errMsg }
            }
        } catch {
            Write-LogMessage "Poll error: $($_.Exception.Message)" -Level Warning
        }
        Start-Sleep -Seconds $TaskPollSeconds
    }
    return @{ Success = $false; Error = "Timed out after $TaskTimeoutMinutes minutes" }
}
#endregion

Write-Host ""
Write-LogMessage "========================================" -Level Info
Write-LogMessage "VSwitch Bond Mode Management" -Level Info
Write-LogMessage "Target: $ClusterName  ->  $TargetBondMode" -Level Info
Write-LogMessage "========================================" -Level Info
Write-Host ""

#region Step 1: Resolve cluster UUID
Write-LogMessage "========================================" -Level Info
Write-LogMessage "Step 1: Resolving cluster UUID for '$ClusterName'" -Level Info
Write-LogMessage "========================================" -Level Info

try {
    $clusterResponse = Invoke-RestMethod -Uri "$BaseUrl/api/clustermgmt/v4.0/config/clusters" `
        -Method GET -Headers $headers -SkipCertificateCheck -ErrorAction Stop
} catch {
    Write-LogMessage "Failed to retrieve clusters from Prism Central: $($_.Exception.Message)" -Level Error
    exit 1
}

$targetCluster = $clusterResponse.data | Where-Object { $_.name -eq $ClusterName }
if (-not $targetCluster) {
    Write-LogMessage "Cluster '$ClusterName' not found in Prism Central" -Level Error
    Write-LogMessage "Available: $(($clusterResponse.data | ForEach-Object { $_.name }) -join ', ')" -Level Info
    exit 1
}

$clusterUuid = $targetCluster.extId
Write-LogMessage "Cluster : $ClusterName" -Level Success
Write-LogMessage "UUID    : $clusterUuid" -Level Success
#endregion

#region Step 2: Find the virtual switch for this cluster
Write-Host ""
Write-LogMessage "========================================" -Level Info
Write-LogMessage "Step 2: Retrieving virtual switch configuration" -Level Info
Write-LogMessage "========================================" -Level Info

try {
    $vswitchResponse = Invoke-RestMethod `
        -Uri "$BaseUrl/api/networking/v4.2/config/virtual-switches?`$page=0&`$limit=50" `
        -Method GET -Headers $headers -SkipCertificateCheck -ErrorAction Stop
} catch {
    Write-LogMessage "Failed to retrieve virtual switches: $($_.Exception.Message)" -Level Error
    exit 1
}

$targetVSwitch = $null
foreach ($vswitch in $vswitchResponse.data) {
    if ($vswitch.clusters | Where-Object { $_.extId -eq $clusterUuid }) {
        $targetVSwitch = $vswitch
        break
    }
}

if (-not $targetVSwitch) {
    Write-LogMessage "No virtual switch found for cluster '$ClusterName' (UUID: $clusterUuid)" -Level Error
    exit 1
}

$vswitchExtId    = $targetVSwitch.extId
$currentBondMode = $targetVSwitch.bondMode

Write-LogMessage "Switch       : $($targetVSwitch.name)" -Level Success
Write-LogMessage "UUID         : $vswitchExtId" -Level Success
Write-LogMessage "Current mode : $currentBondMode" -Level Info
Write-LogMessage "Target mode  : $TargetBondMode" -Level Info
#endregion

#region Step 3: Check bond mode - skip if already correct
Write-Host ""
Write-LogMessage "========================================" -Level Info
Write-LogMessage "Step 3: Evaluating current bond mode" -Level Info
Write-LogMessage "========================================" -Level Info

if ($currentBondMode -eq $TargetBondMode) {
    Write-LogMessage "Bond mode is already '$TargetBondMode' - no change needed." -Level Success
    Write-Host ""
    exit 0
}

Write-LogMessage "Bond mode is '$currentBondMode' - will change to '$TargetBondMode'." -Level Warning
#endregion

#region Step 4: Fetch full vswitch object + build PUT body
Write-Host ""
Write-LogMessage "========================================" -Level Info
Write-LogMessage "Step 4: Preparing and submitting bond mode change" -Level Info
Write-LogMessage "========================================" -Level Info

$vswitchDirectUrl = "$BaseUrl/api/networking/v4.2/config/virtual-switches/$vswitchExtId"
$getHeaders       = $headers.Clone()
$getHeaders['NTNX-Request-Id'] = [System.Guid]::NewGuid().ToString()
$getRespHeaders   = $null

try {
    $vswitchDirect = Invoke-RestMethod -Uri $vswitchDirectUrl -Method GET -Headers $getHeaders `
        -SkipCertificateCheck -ResponseHeadersVariable getRespHeaders -ErrorAction Stop
} catch {
    Write-LogMessage "Failed to fetch virtual switch detail: $($_.Exception.Message)" -Level Error
    exit 1
}
$vswitchObj = if ($vswitchDirect.data) { $vswitchDirect.data } else { $vswitchDirect }

# Extract ETag from response header (required for optimistic concurrency on PUT)
$rawEtag = $null
foreach ($hdrName in @('ETag','Etag','etag','Ntnx-Etag','ntnx-etag','X-Nutanix-Etag')) {
    $vals = $getRespHeaders[$hdrName]
    if ($vals) {
        $rawEtag = ($vals | Select-Object -First 1) -replace '^"(.*)"$', '$1'
        Write-LogMessage "ETag: $rawEtag" -Level Info
        break
    }
}
if (-not $rawEtag) {
    Write-LogMessage "No ETag header returned - PUT will proceed without If-Match." -Level Warning
}

# Deep-clone via JSON round-trip, strip read-only fields, set target bond mode
$vswitchClean = $vswitchObj | ConvertTo-Json -Depth 20 | ConvertFrom-Json
foreach ($f in @('extId','$reserved','$objectType','hasDeploymentError','hasUpdateInProgress')) {
    $vswitchClean.PSObject.Properties.Remove($f)
}
$vswitchClean.bondMode = $TargetBondMode

# isQuickMode = true: apply without rolling maintenance-mode restart
if ($vswitchClean.PSObject.Properties['isQuickMode']) {
    $vswitchClean.isQuickMode = $true
} else {
    $vswitchClean | Add-Member -MemberType NoteProperty -Name 'isQuickMode' -Value $true
}

# Strip read-only fields from nested cluster/host objects
foreach ($cluster in $vswitchClean.clusters) {
    foreach ($f in @('$reserved','$objectType')) { $cluster.PSObject.Properties.Remove($f) }
    foreach ($ahvHost in $cluster.hosts) {
        foreach ($f in @('$reserved','$objectType','internalBridgeName','routeTable')) {
            $ahvHost.PSObject.Properties.Remove($f)
        }
    }
}

$putBodyJson  = $vswitchClean | ConvertTo-Json -Depth 20
$putRequestId = [System.Guid]::NewGuid().ToString()
$putUrl       = "$BaseUrl/api/networking/v4.2/config/virtual-switches/$vswitchExtId"

# Write body to temp file (UTF8 without BOM - Nutanix rejects BOM)
$tempBodyFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "nutanix-vswitch-$putRequestId.json")

try {
    [System.IO.File]::WriteAllText($tempBodyFile, $putBodyJson, [System.Text.UTF8Encoding]::new($false))

    $curlArgs = [System.Collections.Generic.List[string]]::new()
    $curlArgs.AddRange([string[]]@('-sk', '-X', 'PUT', $putUrl))
    $curlArgs.AddRange([string[]]@('-H', "Authorization: Basic $encodedCreds"))
    $curlArgs.AddRange([string[]]@('-H', 'Content-Type: application/json'))
    $curlArgs.AddRange([string[]]@('-H', 'Accept: application/json'))
    $curlArgs.AddRange([string[]]@('-H', "NTNX-Request-Id: $putRequestId"))
    if ($rawEtag) { $curlArgs.AddRange([string[]]@('-H', "If-Match: $rawEtag")) }
    $curlArgs.AddRange([string[]]@('--data-binary', "@$tempBodyFile"))
    $curlArgs.AddRange([string[]]@('-w', "`n%{http_code}"))

    $curlRaw      = & curl.exe @curlArgs 2>&1
    $curlLines    = ($curlRaw -join "`n") -split "`n"
    $statusCode   = [int]($curlLines[-1].Trim())
    $responseBody = ($curlLines[0..($curlLines.Count - 2)] -join "`n").Trim()

    if ($statusCode -ge 200 -and $statusCode -lt 300) {
        $putResponse = $responseBody | ConvertFrom-Json
        Write-LogMessage "Bond mode change submitted (HTTP $statusCode)." -Level Success
        Write-Host ""

        $taskExtId = $putResponse.data.extId
        if ($taskExtId) {
            Write-LogMessage "Task ID : $taskExtId" -Level Info
            Write-Host ""

            # -- Step 5: Poll task --
            Write-LogMessage "========================================" -Level Info
            Write-LogMessage "Step 5: Waiting for task completion" -Level Info
            Write-LogMessage "========================================" -Level Info

            $taskResult = Wait-V4Task -ExtId $taskExtId

            if (-not $taskResult.Success) {
                Write-LogMessage "Task FAILED: $($taskResult.Error)" -Level Error
                exit 1
            }
            Write-LogMessage "Task completed successfully." -Level Success
            Write-Host ""

            # -- Step 6: Verify --
            Write-LogMessage "========================================" -Level Info
            Write-LogMessage "Step 6: Verifying bond mode on virtual switch" -Level Info
            Write-LogMessage "========================================" -Level Info

            try {
                $verifyHeaders = $headers.Clone()
                $verifyHeaders['NTNX-Request-Id'] = [System.Guid]::NewGuid().ToString()
                $verifyResponse = Invoke-RestMethod -Uri $vswitchDirectUrl -Method GET `
                    -Headers $verifyHeaders -SkipCertificateCheck -ErrorAction Stop
                $verifiedObj  = if ($verifyResponse.data) { $verifyResponse.data } else { $verifyResponse }
                $verifiedMode = $verifiedObj.bondMode

                if ($verifiedMode -eq $TargetBondMode) {
                    Write-LogMessage "Virtual switch '$($verifiedObj.name)' bond mode confirmed: $verifiedMode" -Level Success
                } else {
                    Write-LogMessage "MISMATCH - expected '$TargetBondMode' but switch reports '$verifiedMode'." -Level Error
                    exit 1
                }
            } catch {
                Write-LogMessage "Could not re-query switch to verify: $($_.Exception.Message)" -Level Warning
            }
        } else {
            Write-LogMessage "No task ID returned - verify bond mode manually." -Level Warning
        }
    } else {
        Write-LogMessage "PUT FAILED - HTTP $statusCode" -Level Error
        Write-Host $responseBody -ForegroundColor Red
        exit 1
    }
} catch {
    Write-LogMessage "Unexpected error: $($_.Exception.Message)" -Level Error
    exit 1
} finally {
    Remove-Item -Path $tempBodyFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-LogMessage "========================================" -Level Info
Write-LogMessage "VSwitch bond mode management completed!" -Level Success
Write-LogMessage "  Cluster : $ClusterName" -Level Info
Write-LogMessage "  Switch  : $($targetVSwitch.name)" -Level Info
Write-LogMessage "  Mode    : $TargetBondMode" -Level Info
Write-LogMessage "========================================" -Level Info
Write-Host ""