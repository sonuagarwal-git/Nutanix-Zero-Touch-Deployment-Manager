<#
.SYNOPSIS
    Create one or more VLANs on a Nutanix cluster via Prism Central networking v4.2 API.
.DESCRIPTION
    Creates all VLANs defined in the 'production_vlans' array of the config file.
    Cluster lookup uses clustermgmt v4.2 (VIP-aware, stale-registration safe).
    Subnet creation uses networking v4.2 with ipConfig (gateway + network address only; no IPAM pool).
    Task completion is polled via prism v4.0 tasks API.

    API endpoints used:
      Cluster lookup : GET  /api/clustermgmt/v4.2/config/clusters
      Subnet list    : GET  /api/networking/v4.2/config/subnets
      Subnet create  : POST /api/networking/v4.2/config/subnets
      Task poll      : GET  /api/prism/v4.0/config/tasks/{extId}
.EXAMPLE
    .\Create-Nutanix-vLAN.ps1 -ConfigFile ".\Configs\my-cluster.json"
.EXAMPLE
    .\Create-Nutanix-vLAN.ps1 -ConfigFile ".\Configs\my-cluster.json" -SkipExistingCheck

.NOTES
    Author: Sonu Agarwal
    Date: Mar 29, 2026
    Version: 1.0
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [switch]$SkipExistingCheck = $false,

    [Parameter(Mandatory = $false)]
    [int]$TaskTimeoutMinutes = 5,

    [Parameter(Mandatory = $false)]
    [int]$TaskPollSeconds = 5
)

# ─── Load config ──────────────────────────────────────────────────────────────
$config         = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
$PrismCentralIP = $config.prism_central.ip
$pcBaseUrl      = $config.prism_central.url.TrimEnd('/')
$PCUsername     = $config.prism_central.username
$PCPassword     = $config.prism_central.password
$clusterName    = $config.clusterName
$clusterVip     = $config.network.cluster_vip

# Build the full VLAN list:
#   1. MGMT vLAN from the 'network' section (if subnet_name + vlan_id are present)
#   2. All production VLANs from 'production_vlans'
$vlans = @()
$netSection = $config.network
if ($netSection.subnet_name -and $null -ne $netSection.vlan_id) {
    $vlans += [PSCustomObject]@{
        subnet_name   = $netSection.subnet_name
        vlan_id       = $netSection.vlan_id
        gateway       = $netSection.gateway
        prefix_length = $netSection.prefix_length
    }
}
if ($config.production_vlans) {
    $vlans += @($config.production_vlans)
}

if (-not $vlans -or $vlans.Count -eq 0) {
    Write-Host "ERROR: No VLANs defined in 'network' or 'production_vlans' in config file: $ConfigFile" -ForegroundColor Red
    exit 1
}

# SSL bypass
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
$PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true

$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${PCUsername}:${PCPassword}"))
$headers = @{
    'Authorization'   = "Basic $base64Auth"
    'Content-Type'    = 'application/json'
    'Accept'          = 'application/json'
    'NTNX-Request-Id' = [Guid]::NewGuid().ToString()
}

# ─── Helper: derive network address from a host IP + prefix length ──────────
# The API ipSubnet.ip field requires the NETWORK address (e.g. 10.0.56.96/28),
# NOT the gateway/host address (e.g. 10.0.56.97). This masks the IP accordingly.
function Get-NetworkAddress {
    param([string]$IpAddress, [int]$PrefixLength)
    $bytes = [System.Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
    for ($i = 0; $i -lt 4; $i++) {
        $netBits = [Math]::Max(0, [Math]::Min(8, $PrefixLength - $i * 8))
        if ($netBits -lt 8) {
            $maskByte  = if ($netBits -eq 0) { 0 } else { (0xFF -shl (8 - $netBits)) -band 0xFF }
            $bytes[$i] = [byte]([int]$bytes[$i] -band $maskByte)
        }
    }
    return "$($bytes[0]).$($bytes[1]).$($bytes[2]).$($bytes[3])"
}

# ─── Helper: poll a prism v4.0 task ───────────────────────────────────────────
function Wait-V4Task {
    param([string]$ExtId)
    $deadline   = (Get-Date).AddMinutes($TaskTimeoutMinutes)
    $start      = Get-Date
    $lastStatus = ''
    $taskUrl    = "$pcBaseUrl/api/prism/v4.0/config/tasks/$([Uri]::EscapeDataString($ExtId))"
    Write-Host "    Polling task: $ExtId" -ForegroundColor Gray
    while ((Get-Date) -lt $deadline) {
        $elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds)
        try {
            $task   = (Invoke-RestMethod -Method GET -Uri $taskUrl -Headers $headers -TimeoutSec 30).data
            $status = $task.status
            $pct    = if ($null -ne $task.progressPercentage) { [int]$task.progressPercentage } else { 0 }
            if ($status -ne $lastStatus) {
                $color = switch ($status) { 'SUCCEEDED'{'Green'} 'FAILED'{'Red'} 'RUNNING'{'White'} default{'Gray'} }
                Write-Host ("    [{0,4}s] {1,9}  {2,3}%" -f $elapsed, $status, $pct) -ForegroundColor $color
                $lastStatus = $status
            }
            if ($status -eq 'SUCCEEDED') { return @{ Success = $true } }
            if ($status -in @('FAILED','CANCELLED','ABORTED')) {
                $errMsg = if ($task.errorMessages) { ($task.errorMessages | ForEach-Object { $_.message }) -join '; ' } else { 'No details' }
                return @{ Success = $false; Error = $errMsg }
            }
        } catch {
            Write-Host ("    [{0,4}s] Poll error: {1}" -f $elapsed, $_.Exception.Message) -ForegroundColor Yellow
        }
        Start-Sleep -Seconds $TaskPollSeconds
    }
    return @{ Success = $false; Error = "Timed out after $TaskTimeoutMinutes minutes" }
}

# ─── Banner ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "    Create VLANs — networking v4.2 API (via PC)                " -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Cluster       : $clusterName" -ForegroundColor Gray
Write-Host "  Prism Central : $PrismCentralIP" -ForegroundColor Gray
Write-Host "  VLANs to create: $($vlans.Count)" -ForegroundColor Gray
Write-Host ""

# ─── Step 1: Resolve cluster extId (VIP-aware, stale-safe) ────────────────────
Write-Host "Step 1: Finding cluster '$clusterName' in Prism Central..." -ForegroundColor Yellow

$encodedName = [Uri]::EscapeDataString("name eq '$clusterName'")
try {
    $resp       = Invoke-RestMethod -Uri "$pcBaseUrl/api/clustermgmt/v4.2/config/clusters?`$filter=$encodedName&`$limit=50" `
                      -Method GET -Headers $headers -TimeoutSec 30
    $allMatches = @($resp.data) | Where-Object { $_ -and $_.name -eq $clusterName }

    if (-not $allMatches -or $allMatches.Count -eq 0) {
        $resp2      = Invoke-RestMethod -Uri "$pcBaseUrl/api/clustermgmt/v4.2/config/clusters?`$limit=50" `
                          -Method GET -Headers $headers -TimeoutSec 30
        $allMatches = @($resp2.data) | Where-Object { $_.name -eq $clusterName }
    }

    if (-not $allMatches -or $allMatches.Count -eq 0) {
        Write-Host "  ✗ Cluster '$clusterName' not found in Prism Central!" -ForegroundColor Red
        exit 1
    }

    # Prefer cluster whose VIP matches config
    $target = $allMatches | Where-Object { $_.network.externalAddress.ipv4.value -eq $clusterVip } | Select-Object -First 1
    if (-not $target) {
        $target = $allMatches | Select-Object -First 1
        if ($allMatches.Count -gt 1) {
            Write-Host "  ⚠ Multiple clusters named '$clusterName' — picking first (no VIP match)." -ForegroundColor Yellow
        }
    }

    $clusterExtId = $target.extId
    Write-Host "  ✓ Found cluster: $clusterName  (extId: $clusterExtId)" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Failed to retrieve cluster list: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ─── Step 2: Fetch existing subnets for duplicate check ───────────────────────
$existingSubnets = @()
if (-not $SkipExistingCheck) {
    Write-Host "`nStep 2: Fetching existing subnets..." -ForegroundColor Yellow

    # Re-issue with a fresh request ID
    $headers['NTNX-Request-Id'] = [Guid]::NewGuid().ToString()
    # clusterReference is not an OData-filterable field — fetch all subnets and
    # filter client-side by clusterReference matching our target cluster extId.
    try {
        $page = 0; $pageSize = 50; $allSubnets = @()
        do {
            $headers['NTNX-Request-Id'] = [Guid]::NewGuid().ToString()
            $subnetResp = Invoke-RestMethod `
                -Uri "$pcBaseUrl/api/networking/v4.2/config/subnets?`$page=$page&`$limit=$pageSize" `
                -Method GET -Headers $headers -TimeoutSec 30
            $batch      = @($subnetResp.data) | Where-Object { $_ }
            $allSubnets += $batch
            $total      = $subnetResp.metadata.totalAvailableResults
            $page++
        } while ($allSubnets.Count -lt $total)

        # Keep only subnets belonging to this cluster
        $existingSubnets = $allSubnets | Where-Object { $_.clusterReference -eq $clusterExtId }
        Write-Host "  ✓ Retrieved $($allSubnets.Count) / $total subnet(s) total; $($existingSubnets.Count) on this cluster" -ForegroundColor Green
    } catch {
        Write-Host "  ⚠ Could not fetch existing subnets (will skip duplicate check): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ─── Step 3+: Create each VLAN ────────────────────────────────────────────────
$stepNum = if ($SkipExistingCheck) { 2 } else { 3 }
$results = @()
$createUri = "$pcBaseUrl/api/networking/v4.2/config/subnets"

foreach ($vlan in $vlans) {
    $subnetName   = $vlan.subnet_name
    $vlanId       = [int]$vlan.vlan_id
    $gateway      = $vlan.gateway
    $prefixLength = [int]$vlan.prefix_length

    Write-Host "`nStep ${stepNum}: Creating VLAN '$subnetName' (ID: $vlanId)..." -ForegroundColor Yellow
    $stepNum++

    # Duplicate check — skip if same name OR same VLAN ID already exists on this cluster.
    # $existingSubnets is already pre-filtered to this cluster only (Step 2).
    if (-not $SkipExistingCheck -and $existingSubnets.Count -gt 0) {
        $dupByName = $existingSubnets | Where-Object { $_.name -eq $subnetName } | Select-Object -First 1
        $dupById   = $existingSubnets | Where-Object { [int]$_.networkId -eq $vlanId } | Select-Object -First 1

        if ($dupByName) {
            Write-Host "  ⚠ VLAN '$subnetName' already exists on this cluster (extId: $($dupByName.extId)) — skipping." -ForegroundColor Yellow
            $results += [PSCustomObject]@{ Name = $subnetName; VLANID = $vlanId; Status = 'Skipped (name exists)' }
            continue
        }
        if ($dupById) {
            Write-Host "  ⚠ VLAN ID $vlanId already exists on this cluster as '$($dupById.name)' (extId: $($dupById.extId)) — skipping." -ForegroundColor Yellow
            $results += [PSCustomObject]@{ Name = $subnetName; VLANID = $vlanId; Status = "Skipped (VLAN ID $vlanId exists as '$($dupById.name)')" }
            continue
        }
    }

    # Build v4.2 subnet payload per official API schema
    $subnetBody = @{
        name             = $subnetName
        subnetType       = 'VLAN'
        networkId        = $vlanId
        clusterReference = $clusterExtId
    }

    # Add ipConfig whenever gateway + prefix are provided (network address + gateway only; no IPAM pool).
    if ($gateway -and $prefixLength) {
        $networkAddr = Get-NetworkAddress -IpAddress $gateway -PrefixLength $prefixLength

        $ipv4Config = @{
            ipSubnet         = @{
                ip           = @{ value = $networkAddr; prefixLength = 32 }
                prefixLength = $prefixLength
            }
            defaultGatewayIp = @{ value = $gateway; prefixLength = 32 }
        }

        $subnetBody['ipConfig'] = @( @{ ipv4 = $ipv4Config } )
    }

    $headers['NTNX-Request-Id'] = [Guid]::NewGuid().ToString()
    try {
        $createResp = Invoke-RestMethod -Uri $createUri -Method POST `
            -Headers $headers -Body ($subnetBody | ConvertTo-Json -Depth 10) -TimeoutSec 30

        $taskExtId = $createResp.data.extId
        if ($taskExtId) {
            $taskResult = Wait-V4Task -ExtId $taskExtId
            if ($taskResult.Success) {
                Write-Host "  ✓ VLAN '$subnetName' created successfully!" -ForegroundColor Green
                $results += [PSCustomObject]@{ Name = $subnetName; VLANID = $vlanId; Status = 'Created' }
            } else {
                Write-Host "  ✗ Task failed: $($taskResult.Error)" -ForegroundColor Red
                $results += [PSCustomObject]@{ Name = $subnetName; VLANID = $vlanId; Status = "FAILED: $($taskResult.Error)" }
            }
        } else {
            # Synchronous response (no task)
            Write-Host "  ✓ VLAN '$subnetName' created successfully!" -ForegroundColor Green
            $results += [PSCustomObject]@{ Name = $subnetName; VLANID = $vlanId; Status = 'Created' }
        }
    } catch {
        $errMsg = try { ($_.ErrorDetails.Message | ConvertFrom-Json).data.error.validationErrorMessages[0].message } catch { $null }
        if (-not $errMsg) { $errMsg = try { ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch { $_.Exception.Message } }
        Write-Host "  ✗ Failed to create VLAN '$subnetName': $errMsg" -ForegroundColor Red
        $results += [PSCustomObject]@{ Name = $subnetName; VLANID = $vlanId; Status = "FAILED: $errMsg" }
    }
}

# ─── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("═" * 65) -ForegroundColor Cyan
Write-Host "  VLAN CREATION SUMMARY" -ForegroundColor Green
Write-Host ("═" * 65) -ForegroundColor Cyan
Write-Host "  Cluster       : $clusterName" -ForegroundColor White
Write-Host "  Prism Central : $PrismCentralIP" -ForegroundColor White
Write-Host ""
$results | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("═" * 65) -ForegroundColor Cyan

$failed = $results | Where-Object { $_.Status -like 'FAILED*' }
if ($failed) {
    Write-Host "`n  ✗ $($failed.Count) VLAN(s) failed to create." -ForegroundColor Red
    exit 1
}

Write-Host "`n  ✓ All VLANs processed successfully." -ForegroundColor Green
exit 0
exit 0
