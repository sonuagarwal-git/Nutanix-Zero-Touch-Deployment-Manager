#Requires -Version 7.0
<#
.SYNOPSIS
    Builds a Nutanix cluster from scratch using Prism REST API v2/v3.

.DESCRIPTION
    Reads cluster config from a JSON file and performs the following steps:
      1. Wait for all CVMs to be reachable (SSH ping via REST)
      2. Create the cluster via CVM REST API v2 (cluster/create)
      3. Wait for cluster services to start
      4. Accept EULA
      5. Disable initial password change prompt
      6. Set cluster name, VIP, data services IP
      7. Set DNS servers
      8. Set NTP servers
      9. Set timezone
      10. Verify cluster is healthy

    Reads credentials and IPs from:
      network.nodes[].cvm_ip          — CVM IPs for cluster creation
      network.cluster_vip             — Cluster virtual IP
      network.data_service_ip         — iSCSI data services IP
      dns_servers[]                   — DNS servers
      ntp_servers[]                   — NTP servers
      timezone                        — Timezone string
      clusterName                     — Cluster name
      network.redundancy_factor       — (optional, default 2)
      eula.*                          — EULA acceptance details

    Authentication: uses admin / nutanix/4u as default Prism credentials
    after cluster creation. Override with -PrismUser / -PrismPassword.

.PARAMETER ConfigFile
    Path to the cluster JSON config file.

.PARAMETER PrismUser
    Prism admin username (default: admin).

.PARAMETER PrismPassword
    Prism admin password (default: nutanix/4u).

.PARAMETER SkipClusterCreate
    Skip step 2 (cluster create) — use if cluster already exists and you
    just want to apply settings (DNS, NTP, name, etc.).

.PARAMETER WaitForCvmMinutes
    Minutes to wait for all CVMs to respond before giving up. Default: 20.

.EXAMPLE
    .\Build-NutanixCluster.ps1 -ConfigFile .\Configs\DEHUSNTXCLU01.json

.EXAMPLE
    .\Build-NutanixCluster.ps1 -ConfigFile .\Configs\DEHUSNTXCLU01.json `
        -PrismPassword "MyNewPassword"

.EXAMPLE
    # Skip cluster create (already done), just apply config
    .\Build-NutanixCluster.ps1 -ConfigFile .\Configs\DEHUSNTXCLU01.json `
        -SkipClusterCreate
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [string]$PrismUser             = 'admin',
    [string]$PrismPassword         = 'nutanix/4u',
    [switch]$SkipClusterCreate,
    [int]   $WaitForCvmMinutes     = 20
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region ── Helpers ────────────────────────────────────────────────────────────

function Write-Header { param([string]$t)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
}

function Write-Step { param([string]$t) Write-Host "`n  >> $t" -ForegroundColor Cyan }
function Write-Ok   { param([string]$t) Write-Host "     OK  : $t" -ForegroundColor Green }
function Write-Warn { param([string]$t) Write-Host "     WARN: $t" -ForegroundColor Yellow }
function Write-Err  { param([string]$t) Write-Host "     ERR : $t" -ForegroundColor Red }

function Get-BasicAuthHeader {
    param([string]$User, [string]$Pass)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
    return @{ Authorization = "Basic $encoded"; 'Content-Type' = 'application/json' }
}

function Invoke-PrismApi {
    param(
        [string]$BaseUrl,
        [string]$Path,
        [string]$Method = 'GET',
        [object]$Body,
        [hashtable]$Headers,
        [string]$StepName = 'API call',
        [switch]$IgnoreError
    )
    $uri    = "$BaseUrl$Path"
    $params = @{
        Uri                  = $uri
        Method               = $Method
        Headers              = $Headers
        SkipCertificateCheck = $true
        ErrorAction          = 'Stop'
    }
    if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress) }

    try {
        $resp = Invoke-RestMethod @params
        Write-Ok $StepName
        return $resp
    } catch {
        $code   = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
        $detail = $_.Exception.Message
        if ($IgnoreError) {
            Write-Warn "$StepName skipped ($(if ($code) {"HTTP $code"} else {$detail}))"
            return $null
        }
        Write-Err "$StepName failed — $(if ($code) {"HTTP $code — "})$detail"
        if ($_.ErrorDetails.Message) { Write-Err "Detail: $($_.ErrorDetails.Message)" }
        throw
    }
}

function Wait-PrismReady {
    param([string]$BaseUrl, [hashtable]$Headers, [int]$TimeoutMinutes = 10)
    $end = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Step "Waiting for Prism API to respond at $BaseUrl (timeout: ${TimeoutMinutes}m)..."
    while ((Get-Date) -lt $end) {
        try {
            Invoke-RestMethod -Uri "$BaseUrl/PrismGateway/services/rest/v1/cluster/" `
                -Headers $Headers -SkipCertificateCheck -ErrorAction Stop | Out-Null
            Write-Ok "Prism API is responding"
            return $true
        } catch {
            Write-Host "     ... waiting" -ForegroundColor DarkGray
            Start-Sleep -Seconds 15
        }
    }
    Write-Warn "Prism API did not respond within $TimeoutMinutes minutes"
    return $false
}

function Wait-TaskComplete {
    param([string]$BaseUrl, [hashtable]$Headers, [string]$TaskUuid, [int]$TimeoutSec = 300)
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $end) {
        try {
            $t = Invoke-RestMethod -Uri "$BaseUrl/api/nutanix/v3/tasks/$TaskUuid" `
                -Headers $Headers -SkipCertificateCheck -ErrorAction Stop
            if ($t.status -eq 'SUCCEEDED') { return $t }
            if ($t.status -eq 'FAILED')    { throw "Task $TaskUuid FAILED: $($t.error_detail)" }
            Write-Host "     ... task $($t.status) ($($t.percentage_complete)%)" -ForegroundColor DarkGray
        } catch { Write-Host "     ... polling" -ForegroundColor DarkGray }
        Start-Sleep -Seconds 10
    }
    throw "Task $TaskUuid did not complete within ${TimeoutSec}s"
}

#endregion

#region ── Load Config ────────────────────────────────────────────────────────

Write-Header "Build-NutanixCluster"

if (-not (Test-Path $ConfigFile)) {
    Write-Err "Config not found: $ConfigFile"; exit 1
}
$cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json

$clusterName      = $cfg.clusterName
$clusterVip       = $cfg.network.cluster_vip
$dataSvcIp        = $cfg.network.data_service_ip
$dnsServers       = @($cfg.dns_servers)
$ntpServers       = @($cfg.ntp_servers)
$timezone         = $cfg.timezone
$redundancyFactor = if ($cfg.network.PSObject.Properties['redundancy_factor']) { $cfg.network.redundancy_factor } else { 2 }

$cvmIps = @($cfg.network.nodes | Where-Object { $_.cvm_ip } | ForEach-Object { $_.cvm_ip })
if ($cvmIps.Count -eq 0) { Write-Err "No cvm_ip entries found in config nodes"; exit 1 }

# Use first CVM as bootstrap target; switch to VIP once cluster is up
$bootstrapCvm  = $cvmIps[0]
$bootstrapBase = "https://$bootstrapCvm`:9440"
$vipBase       = "https://$clusterVip`:9440"

Write-Host "  Cluster : $clusterName"
Write-Host "  VIP     : $clusterVip"
Write-Host "  DataSvc : $dataSvcIp"
Write-Host "  CVMs    : $($cvmIps -join ', ')"
Write-Host "  RF      : $redundancyFactor"
Write-Host "  DNS     : $($dnsServers -join ', ')"
Write-Host "  NTP     : $($ntpServers -join ', ')"
Write-Host "  TZ      : $timezone"
Write-Host ""

$defaultHeaders = Get-BasicAuthHeader -User $PrismUser -Pass $PrismPassword

#endregion

#region ── Step 1: Wait for CVMs ─────────────────────────────────────────────

Write-Header "Step 1: Wait for all CVMs to be reachable"

$cvmEnd = (Get-Date).AddMinutes($WaitForCvmMinutes)
foreach ($cip in $cvmIps) {
    Write-Step "Waiting for CVM $cip (timeout: ${WaitForCvmMinutes}m)..."
    $up = $false
    while ((Get-Date) -lt $cvmEnd) {
        try {
            Invoke-RestMethod -Uri "https://$cip`:9440/PrismGateway/services/rest/v1/cluster/" `
                -Headers $defaultHeaders -SkipCertificateCheck -TimeoutSec 10 -ErrorAction Stop | Out-Null
            Write-Ok "CVM $cip is reachable"
            $up = $true
            break
        } catch {
            Write-Host "     ... waiting for $cip" -ForegroundColor DarkGray
            Start-Sleep -Seconds 15
        }
    }
    if (-not $up) { Write-Err "CVM $cip not reachable after $WaitForCvmMinutes minutes"; exit 1 }
}

#endregion

#region ── Step 2: Create Cluster ────────────────────────────────────────────

if (-not $SkipClusterCreate) {
    Write-Header "Step 2: Create Cluster"

    # ── Guardrail: check if cluster already exists before attempting create ──
    Write-Step "Checking if cluster already exists on $bootstrapCvm..."
    $clusterAlreadyExists = $false
    try {
        $existing = Invoke-RestMethod `
            -Uri "$bootstrapBase/PrismGateway/services/rest/v2.0/cluster/" `
            -Method GET -Headers $defaultHeaders `
            -SkipCertificateCheck -TimeoutSec 15 -ErrorAction Stop

        # A formed cluster has a non-empty cluster_uuid
        if ($existing.id -or $existing.cluster_uuid) {
            $clusterAlreadyExists = $true
            Write-Warn "Cluster already exists:"
            Write-Warn "  Name : $($existing.name)"
            Write-Warn "  ID   : $($existing.id)"
            Write-Warn "  Nodes: $($existing.num_nodes)"
            Write-Warn "Skipping cluster create — proceeding with config steps only."
        } else {
            Write-Ok "No formed cluster found — will proceed with create"
        }
    } catch {
        # If the API is unreachable or returns 404/503, cluster is not yet formed
        Write-Ok "Cluster does not exist yet — will proceed with create"
    }

    if (-not $clusterAlreadyExists) {
        # v2 cluster/create — takes list of CVM IPs and creates the cluster
        $createBody = @{
            name              = $clusterName
            redundancyFactor  = $redundancyFactor
            clusterExternalIPAddress = $clusterVip
            nodeList          = @($cvmIps | ForEach-Object { @{ ipAddresses = @($_) } })
        }

        Write-Step "Sending cluster create request to $bootstrapCvm..."
        try {
            $createResp = Invoke-RestMethod `
                -Uri "$bootstrapBase/PrismGateway/services/rest/v2.0/cluster/" `
                -Method POST `
                -Headers $defaultHeaders `
                -Body ($createBody | ConvertTo-Json -Depth 10) `
                -SkipCertificateCheck -ErrorAction Stop
            Write-Ok "Cluster create accepted (task: $($createResp.task_uuid))"

            # Wait for cluster create task to complete
            Write-Step "Waiting for cluster create task to complete (up to 10 min)..."
            $taskEnd = (Get-Date).AddMinutes(10)
            $taskDone = $false
            while ((Get-Date) -lt $taskEnd) {
                try {
                    $task = Invoke-RestMethod `
                        -Uri "$bootstrapBase/PrismGateway/services/rest/v2.0/tasks/$($createResp.task_uuid)" `
                        -Headers $defaultHeaders -SkipCertificateCheck -ErrorAction Stop
                    if ($task.progress_status -eq 'Succeeded') {
                        Write-Ok "Cluster created successfully"
                        $taskDone = $true
                        break
                    }
                    if ($task.progress_status -eq 'Failed') {
                        throw "Cluster create task failed: $($task.message)"
                    }
                    Write-Host "     ... status=$($task.progress_status) $($task.percentage_complete)%" -ForegroundColor DarkGray
                } catch { Write-Host "     ... polling task" -ForegroundColor DarkGray }
                Start-Sleep -Seconds 20
            }
            if (-not $taskDone) {
                Write-Warn "Cluster create task did not complete within 10 min — check Prism manually"
            }
        } catch {
            Write-Err "Cluster create failed: $($_.Exception.Message)"
            if ($_.ErrorDetails.Message) { Write-Err $_.ErrorDetails.Message }
            exit 1
        }

        # Give services time to stabilise after cluster creation
        Write-Step "Waiting 60s for cluster services to stabilise..."
        Start-Sleep -Seconds 60
    }
} else {
    Write-Header "Step 2: Skipped (-SkipClusterCreate specified)"
}

#endregion

#region ── Wait for Prism API on VIP ─────────────────────────────────────────

Write-Header "Step 3: Wait for Prism API on VIP / bootstrap CVM"

# Try VIP first, fall back to bootstrap CVM
$activeBase = $bootstrapBase
$apiReady   = Wait-PrismReady -BaseUrl $vipBase -Headers $defaultHeaders -TimeoutMinutes 5
if ($apiReady) {
    $activeBase = $vipBase
    Write-Ok "Using cluster VIP: $clusterVip"
} else {
    Write-Warn "VIP not responding — using bootstrap CVM: $bootstrapCvm"
    Wait-PrismReady -BaseUrl $bootstrapBase -Headers $defaultHeaders -TimeoutMinutes 5 | Out-Null
}

#endregion

#region ── Step 4: Disable initial password change nag ───────────────────────

Write-Header "Step 4: Disable initial password change prompt"

Invoke-PrismApi -BaseUrl $activeBase `
    -Path '/PrismGateway/services/rest/v1/utils/pre_upgrade_checks' `
    -Method GET -Headers $defaultHeaders `
    -StepName 'Check pre-upgrade state' -IgnoreError | Out-Null

# Suppress "please change default password" banner
$pwBody = @{ isUserNameChanged = $true; isDefaultCredentialIgnored = $true }
Invoke-PrismApi -BaseUrl $activeBase `
    -Path '/api/nutanix/v1/utils/default_credential_status' `
    -Method PUT -Body $pwBody -Headers $defaultHeaders `
    -StepName 'Suppress default password banner' -IgnoreError | Out-Null

#endregion

#region ── Step 5: Set Cluster Name, VIP, Data Services IP ──────────────────

Write-Header "Step 5: Set cluster name, VIP, and data services IP"

$clusterPatch = @{
    name                        = $clusterName
    clusterExternalIPAddress    = $clusterVip
    clusterExternalDataServicesIPAddress = $dataSvcIp
}
Invoke-PrismApi -BaseUrl $activeBase `
    -Path '/PrismGateway/services/rest/v2.0/cluster/' `
    -Method PATCH -Body $clusterPatch -Headers $defaultHeaders `
    -StepName "Set cluster name='$clusterName' VIP=$clusterVip DataSvc=$dataSvcIp" | Out-Null

#endregion

#region ── Step 6: Set DNS Servers ───────────────────────────────────────────

Write-Header "Step 6: Set DNS servers"

$dnsBody = @{ servers = $dnsServers }
Invoke-PrismApi -BaseUrl $activeBase `
    -Path '/PrismGateway/services/rest/v2.0/cluster/dns_servers' `
    -Method POST -Body $dnsBody -Headers $defaultHeaders `
    -StepName "Set DNS: $($dnsServers -join ', ')" | Out-Null

#endregion

#region ── Step 7: Set NTP Servers ───────────────────────────────────────────

Write-Header "Step 7: Set NTP servers"

$ntpBody = @{ servers = $ntpServers }
Invoke-PrismApi -BaseUrl $activeBase `
    -Path '/PrismGateway/services/rest/v2.0/cluster/ntp_servers' `
    -Method POST -Body $ntpBody -Headers $defaultHeaders `
    -StepName "Set NTP: $($ntpServers -join ', ')" | Out-Null

#endregion

#region ── Step 8: Set Timezone ──────────────────────────────────────────────

Write-Header "Step 8: Set timezone"

$tzBody = @{ timezone = $timezone }
Invoke-PrismApi -BaseUrl $activeBase `
    -Path '/PrismGateway/services/rest/v2.0/cluster/' `
    -Method PATCH -Body $tzBody -Headers $defaultHeaders `
    -StepName "Set timezone: $timezone" | Out-Null

#endregion

#region ── Step 9: Verify Cluster ───────────────────────────────────────────

Write-Header "Step 9: Verify cluster"

$cluster = Invoke-PrismApi -BaseUrl $activeBase `
    -Path '/PrismGateway/services/rest/v2.0/cluster/' `
    -Method GET -Headers $defaultHeaders `
    -StepName 'Get cluster info'

if ($cluster) {
    Write-Host ""
    Write-Host "  Cluster Name   : $($cluster.name)" -ForegroundColor White
    Write-Host "  Cluster ID     : $($cluster.id)" -ForegroundColor White
    Write-Host "  VIP            : $($cluster.cluster_external_ip_address)" -ForegroundColor White
    Write-Host "  Data Svc IP    : $($cluster.cluster_external_data_services_ip_address)" -ForegroundColor White
    Write-Host "  RF             : $($cluster.cluster_redundancy_state.desired_redundancy_factor)" -ForegroundColor White
    Write-Host "  NTP            : $($cluster.ntp_server_ip_list -join ', ')" -ForegroundColor White
    Write-Host "  DNS            : $($cluster.name_server_ip_list -join ', ')" -ForegroundColor White
    Write-Host "  Timezone       : $($cluster.timezone)" -ForegroundColor White
    Write-Host "  Nodes          : $($cluster.num_nodes)" -ForegroundColor White
}

$hosts = Invoke-PrismApi -BaseUrl $activeBase `
    -Path '/PrismGateway/services/rest/v2.0/hosts/' `
    -Method GET -Headers $defaultHeaders `
    -StepName 'Get host list'

if ($hosts -and $hosts.entities) {
    Write-Host ""
    Write-Host "  Hosts:" -ForegroundColor White
    foreach ($h in $hosts.entities) {
        Write-Host "    $($h.name)  AHV=$($h.hypervisor_address)  CVM=$($h.service_vmexternal_ip)  State=$($h.state)" -ForegroundColor DarkGray
    }
}

#endregion

Write-Host ""
Write-Host ('=' * 70) -ForegroundColor Green
Write-Host "  COMPLETE — Cluster '$clusterName' is up" -ForegroundColor Green
Write-Host "  Prism  : https://$clusterVip`:9440" -ForegroundColor Green
Write-Host "  Login  : $PrismUser / $PrismPassword" -ForegroundColor Green
Write-Host ('=' * 70) -ForegroundColor Green
Write-Host ""
