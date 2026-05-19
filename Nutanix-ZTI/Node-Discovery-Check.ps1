#Requires -Version 7.0
<#
.SYNOPSIS
    Poll Foundation Central until all nodes (by serial number) from the config are discovered.

.DESCRIPTION
    Poll Foundation Central until all nodes (by serial number) from the config are
    discovered AND available for imaging (i.e. Foundation Central reports available=true
    or node_state=STATE_AVAILABLE for each node).

    Nodes in STATE_DISCOVERING are visible in FC but not yet ready — imaging will fail
    if started while nodes are still discovering.  This script waits until every node
    transitions to an available/ready state before reporting success.

    JSON config fields used:
      prism_central.url      — Prism Central / Foundation Central URL (https://ip:9440)
      prism_central.username — admin username
      prism_central.password — admin password
      network.nodes[].serial — Node serial number (used to match discovered nodes)

.PARAMETER ConfigFile
    Path to the cluster JSON config file.

.PARAMETER TimeoutMinutes
    Maximum time to poll (default: 60 minutes).

.PARAMETER PollIntervalSeconds
    Seconds between each poll (default: 60 seconds).

.EXAMPLE
    .\Node-Discover-Check.ps1 -ConfigFile .\Configs\DKCDC-1P-NTXTEST-01.json

.EXAMPLE
    .\Node-Discover-Check.ps1 -ConfigFile .\Configs\DKCDC-1P-NTXTEST-01.json -TimeoutMinutes 30
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter()]
    [int]$TimeoutMinutes = 60,

    [Parameter()]
    [int]$PollIntervalSeconds = 60
)

# ── Setup ─────────────────────────────────────────────────────────────────────
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
$PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
$ErrorActionPreference = 'Stop'

# ── Load config ───────────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigFile)) {
    Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
    exit 1
}

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

if (-not $config.prism_central) {
    Write-Host "ERROR: Config missing 'prism_central' section." -ForegroundColor Red
    exit 1
}

$fcUrl      = $config.prism_central.url
$fcUser     = $config.prism_central.username
$fcPassword = $config.prism_central.password

if (-not $fcUrl -or -not $fcUser -or -not $fcPassword) {
    Write-Host "ERROR: prism_central section must have 'url', 'username', and 'password'." -ForegroundColor Red
    exit 1
}

if (-not $config.network.nodes -or @($config.network.nodes).Count -eq 0) {
    Write-Host "ERROR: No nodes defined in config file (network.nodes)." -ForegroundColor Red
    exit 1
}

# Build expected node list from config
$expectedNodes = @($config.network.nodes | ForEach-Object {
    [PSCustomObject]@{
        Serial       = $_.serial
        Hostname     = $_.hostname
        IloIp        = $_.iLO_ip
        CvmIp        = $_.cvm_ip
        HypervisorIp = $_.hypervisor_ip
    }
}) | Where-Object { $_.Serial }

if ($expectedNodes.Count -eq 0) {
    Write-Host "ERROR: No nodes with 'serial' field found in config." -ForegroundColor Red
    exit 1
}

# ── Auth header ───────────────────────────────────────────────────────────────
$b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${fcUser}:${fcPassword}"))
$headers = @{
    Authorization = "Basic $b64"
    'Content-Type' = 'application/json'
    Accept         = 'application/json'
}

# ── FC API endpoint discovery ─────────────────────────────────────────────────
$apiEndpoints = @(
    @{ Uri = "$fcUrl/api/fc/v1/imaged_nodes/list";                 Method = 'GET'  }
    @{ Uri = "$fcUrl/api/fc/v1/imaged_nodes/list";                 Method = 'POST' }
    @{ Uri = "$fcUrl/api/fc/v1/imaged_nodes";                      Method = 'GET'  }
    @{ Uri = "$fcUrl/dm/foundation_central/api/imaged_nodes/list"; Method = 'GET'  }
    @{ Uri = "$fcUrl/api/foundation_central/v3/imaged_nodes/list"; Method = 'POST' }
    @{ Uri = "$fcUrl/foundation_central/v3/imaged_nodes/list";     Method = 'POST' }
)

function Get-FCNodes {
    $allErrors = @()
    foreach ($ep in $apiEndpoints) {
        try {
            $params = @{
                Uri                  = $ep.Uri
                Method               = $ep.Method
                Headers              = $headers
                TimeoutSec           = 30
                SkipCertificateCheck = $true
                ErrorAction          = 'Stop'
            }
            if ($ep.Method -eq 'POST') {
                $params['Body']        = '{"kind":"imaged_node","length":500}'
                $params['ContentType'] = 'application/json'
            }
            $resp = Invoke-RestMethod @params
            if ($resp -is [string] -and $resp -match '<!doctype html>') {
                $allErrors += "  $($ep.Method) $($ep.Uri) → HTML response (not JSON)"
                continue
            }
            $nodes = if ($resp.imaged_nodes) { $resp.imaged_nodes }
                     elseif ($resp.entities)  { $resp.entities }
                     else { @() }
            Write-Host "  [FC] Connected via: $($ep.Method) $($ep.Uri)" -ForegroundColor DarkGray
            return $nodes
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            $errMsg     = $_.Exception.Message

            # A 400 (Bad Request) means the endpoint EXISTS — use it with proper body
            if ($statusCode -eq 400) {
                Write-Host "  [FC] Connected via (validation): $($ep.Method) $($ep.Uri)" -ForegroundColor DarkGray
                return @()  # endpoint works; no nodes in FC yet is a valid state
            }

            $allErrors += "  $($ep.Method) $($ep.Uri) → HTTP $statusCode — $errMsg"
            continue
        }
    }
    # Print all failures for diagnosis
    foreach ($e in $allErrors) { Write-Host $e -ForegroundColor DarkGray }
    return $null   # all endpoints failed
}

# ── Banner ────────────────────────────────────────────────────────────────────
$clusterName = $config.clusterName
$nodeCount   = $expectedNodes.Count

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Node Discovery Check — Foundation Central" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Cluster       : $clusterName" -ForegroundColor White
Write-Host "  Config        : $ConfigFile" -ForegroundColor White
Write-Host "  FC URL        : $fcUrl" -ForegroundColor White
Write-Host "  Expected Nodes: $nodeCount" -ForegroundColor White
Write-Host "  Timeout       : $TimeoutMinutes min  (poll every $PollIntervalSeconds s)" -ForegroundColor White
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  NOTE: Waits until each node is AVAILABLE for imaging (not just visible in FC)." -ForegroundColor DarkGray
Write-Host "        Nodes in STATE_DISCOVERING are still initialising — imaging cannot start yet." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Expected nodes:" -ForegroundColor Yellow
foreach ($n in $expectedNodes) {
    $iloDisplay = if ($n.IloIp) { "  iLO: $($n.IloIp)" } else { "" }
    Write-Host ("    • {0,-20}  Serial: {1}{2}" -f $n.Hostname, $n.Serial, $iloDisplay) -ForegroundColor White
}
Write-Host ""

# ── Polling loop ──────────────────────────────────────────────────────────────
$deadline    = (Get-Date).AddMinutes($TimeoutMinutes)
$pollCount   = 0
$allFound    = $false

while ((Get-Date) -lt $deadline) {
    $pollCount++
    $elapsed = [int]((Get-Date) - ($deadline.AddMinutes(-$TimeoutMinutes))).TotalSeconds
    $elapsedStr = "{0}m {1:D2}s" -f [int]($elapsed / 60), ($elapsed % 60)
    $remaining  = [int](($deadline - (Get-Date)).TotalSeconds)
    $remainStr  = "{0}m {1:D2}s" -f [int]($remaining / 60), ($remaining % 60)

    Write-Host ("[{0}]  Poll #{1} — elapsed: {2}, remaining: {3}" -f (Get-Date -Format 'HH:mm:ss'), $pollCount, $elapsedStr, $remainStr) -ForegroundColor DarkGray

    $fcNodes = Get-FCNodes

    if ($null -eq $fcNodes) {
        Write-Host "  ⚠ Could not reach Foundation Central — will retry…" -ForegroundColor Yellow
    } else {
        # Build a set of visible serials (normalise to uppercase)
        $visibleSerials = @{}
        foreach ($fn in $fcNodes) {
            $s = if ($fn.node_serial) { $fn.node_serial }
                 elseif ($fn.status.node_serial) { $fn.status.node_serial }
                 else { $null }
            if ($s) { $visibleSerials[$s.ToUpper()] = $fn }
        }

        $foundCount   = 0
        $missingNodes = @()

        foreach ($n in $expectedNodes) {
            $key = $n.Serial.ToUpper()
            if ($visibleSerials.ContainsKey($key)) {
                $fn        = $visibleSerials[$key]
                $nodeState = if ($fn.node_state) { $fn.node_state } elseif ($fn.status.node_state) { $fn.status.node_state } else { 'unknown' }
                $cvmIp     = if ($fn.cvm_ip)     { $fn.cvm_ip }     elseif ($fn.status.cvm_ip)     { $fn.status.cvm_ip }     else { '' }

                # Mirror the availability check used by Image-And-Deploy-Cluster.ps1 exactly:
                # prefer the boolean 'available' field; fall back to state string comparison
                $isAvailable = if ($null -ne $fn.available) { [bool]$fn.available }
                               elseif ($fn.status.state -eq 'AVAILABLE') { $true }
                               else { $nodeState -eq 'STATE_AVAILABLE' }

                if ($isAvailable) {
                    Write-Host ("  ✓ {0,-20}  Serial: {1}  State: {2}{3}" -f $n.Hostname, $n.Serial, $nodeState, $(if ($cvmIp) { "  CVM: $cvmIp" } else { '' })) -ForegroundColor Green
                    $foundCount++
                } else {
                    # Visible but not yet ready for imaging — keep waiting
                    Write-Host ("  ⏳ {0,-20}  Serial: {1}  State: {2} — not yet available for imaging" -f $n.Hostname, $n.Serial, $nodeState) -ForegroundColor Yellow
                    $missingNodes += $n
                }
            } else {
                $iloDisplay = if ($n.IloIp) { "  iLO: $($n.IloIp)" } else { '' }
                Write-Host ("  ✗ {0,-20}  Serial: {1}{2}  — not yet visible in FC" -f $n.Hostname, $n.Serial, $iloDisplay) -ForegroundColor Yellow
                $missingNodes += $n
            }
        }

        Write-Host ("  → {0}/{1} nodes available for imaging" -f $foundCount, $nodeCount) -ForegroundColor Cyan

        if ($foundCount -eq $nodeCount) {
            $allFound = $true
            break
        }
    }

    if ((Get-Date) -lt $deadline) {
        Write-Host ("  Waiting {0}s before next poll…`n" -f $PollIntervalSeconds) -ForegroundColor DarkGray
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

# ── Result ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

if ($allFound) {
    Write-Host "  ✅ All $nodeCount node(s) available for imaging in Foundation Central!" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    # ── Eject ISO from all nodes via iLO Redfish ──────────────────────────────
    Write-Host "  Ejecting mounted ISO from all nodes via iLO..." -ForegroundColor Yellow
    Write-Host ""

    $ejectResults = @()

    foreach ($n in $expectedNodes) {
        $tag = if ($n.Hostname) { "[$($n.Hostname)]" } else { "[Serial:$($n.Serial)]" }

        # Resolve iLO credentials from config node object
        $nodeConfig = $config.network.nodes | Where-Object { $_.serial -eq $n.Serial } | Select-Object -First 1
        $iloIp   = $n.IloIp
        $iloUser = if ($nodeConfig.iLO_username) { $nodeConfig.iLO_username } else { $null }
        $iloPwd  = if ($nodeConfig.iLO_password) { $nodeConfig.iLO_password } else { $null }

        if (-not $iloIp -or -not $iloUser -or -not $iloPwd) {
            Write-Host "  $tag ⚠ Skipping ISO eject — iLO credentials not found in config (need iLO_ip, iLO_username, iLO_password)." -ForegroundColor Yellow
            $ejectResults += [PSCustomObject]@{ Hostname = $n.Hostname; Result = 'Skipped (no iLO creds)' }
            continue
        }

        $iloBase = "https://$iloIp"
        $session = $null

        try {
            # Create Redfish session — use Invoke-WebRequest so response headers are accessible.
            # Invoke-RestMethod returns only the parsed JSON body; X-Auth-Token lives in the
            # HTTP response headers and is not accessible via $response.Headers on that object.
            $sessUri     = "$iloBase/redfish/v1/SessionService/Sessions/"
            $sessBody    = @{ UserName = $iloUser; Password = $iloPwd } | ConvertTo-Json
            $sessRespRaw = Invoke-WebRequest -Uri $sessUri -Method POST -Body $sessBody `
                -ContentType 'application/json' -SkipCertificateCheck -TimeoutSec 20 -ErrorAction Stop
            # In PowerShell 7, header values are string[]; cast to [string] to get a plain token.
            $sessToken    = [string]($sessRespRaw.Headers['X-Auth-Token'] | Select-Object -First 1)
            $sessLocation = [string]($sessRespRaw.Headers['Location']     | Select-Object -First 1)
            $redfishHdrs = @{ 'X-Auth-Token' = $sessToken; 'Content-Type' = 'application/json' }

            Write-Host "  $tag [OK] iLO session created" -ForegroundColor Green

            # Eject virtual media slot 2 (CD/DVD — Phoenix ISO)
            $ejectUri  = "$iloBase/redfish/v1/Managers/1/VirtualMedia/2/Actions/Oem/Hpe/HpeiLOVirtualMedia.EjectVirtualMedia/"
            $ejectBody = '{}' 
            try {
                Invoke-RestMethod -Uri $ejectUri -Method POST -Body $ejectBody -Headers $redfishHdrs `
                    -SkipCertificateCheck -TimeoutSec 20 -ErrorAction Stop | Out-Null
                Write-Host "  $tag ✅ ISO ejected successfully." -ForegroundColor Green
                $ejectResults += [PSCustomObject]@{ Hostname = $n.Hostname; Result = 'Ejected' }
            } catch {
                $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'N/A' }
                # HTTP 400 often means nothing was mounted — treat as success
                if ($sc -eq 400) {
                    Write-Host "  $tag ✅ No ISO mounted (nothing to eject)." -ForegroundColor Green
                    $ejectResults += [PSCustomObject]@{ Hostname = $n.Hostname; Result = 'Already empty' }
                } else {
                    Write-Host "  $tag ⚠ Eject failed (HTTP $sc): $($_.Exception.Message)" -ForegroundColor Yellow
                    $ejectResults += [PSCustomObject]@{ Hostname = $n.Hostname; Result = "Failed (HTTP $sc)" }
                }
            }

            # Close Redfish session
            if ($sessLocation) {
                try {
                    Invoke-RestMethod -Uri $sessLocation -Method DELETE -Headers $redfishHdrs `
                        -SkipCertificateCheck -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
                } catch {}
            }

        } catch {
            Write-Host "  $tag ⚠ Could not connect to iLO ($iloIp): $($_.Exception.Message)" -ForegroundColor Yellow
            $ejectResults += [PSCustomObject]@{ Hostname = $n.Hostname; Result = "iLO connect failed" }
        }
    }

    Write-Host ""
    Write-Host "  ISO Eject Summary:" -ForegroundColor Cyan
    foreach ($r in $ejectResults) {
        $color = if ($r.Result -match 'Ejected|empty') { 'Green' } elseif ($r.Result -match 'Skipped|Failed|failed') { 'Yellow' } else { 'White' }
        Write-Host ("    • {0,-25}  {1}" -f $r.Hostname, $r.Result) -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    exit 0
} else {
    $totalElapsedMin = [int]((Get-Date) - ($deadline.AddMinutes(-$TimeoutMinutes))).TotalMinutes
    Write-Host "  ❌ Discovery timed out after $totalElapsedMin minutes." -ForegroundColor Red
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host ""
    Write-Host "  The following node(s) were NOT discovered in Foundation Central:" -ForegroundColor Red
    Write-Host ""

    # Re-run one final check to get the exact missing list
    $fcNodes = Get-FCNodes
    $visibleSerials = @{}
    if ($fcNodes) {
        foreach ($fn in $fcNodes) {
            $s = if ($fn.node_serial) { $fn.node_serial } elseif ($fn.status.node_serial) { $fn.status.node_serial } else { $null }
            if ($s) { $visibleSerials[$s.ToUpper()] = $fn }
        }
    }

    foreach ($n in $expectedNodes) {
        if (-not $visibleSerials.ContainsKey($n.Serial.ToUpper())) {
            $iloDisplay = if ($n.IloIp) { $n.IloIp } else { 'unknown' }
            Write-Host "  ┌─────────────────────────────────────────" -ForegroundColor Red
            Write-Host "  │  Hostname  : $($n.Hostname)"             -ForegroundColor White
            Write-Host "  │  Serial    : $($n.Serial)"               -ForegroundColor White
            Write-Host "  │  iLO IP    : $iloDisplay"                -ForegroundColor White
            Write-Host "  │  CVM IP    : $($n.CvmIp)"               -ForegroundColor White
            Write-Host "  └─────────────────────────────────────────" -ForegroundColor Red
            Write-Host ""
        }
    }

    Write-Host "  What to do next:" -ForegroundColor Yellow
    Write-Host "  1. Verify the node(s) finished booting into Phoenix OS." -ForegroundColor White
    Write-Host "     Run: .\Phoonix-Boot-Check.ps1 -ConfigFile $ConfigFile" -ForegroundColor Gray
    Write-Host "  2. Check Foundation Central UI: $fcUrl" -ForegroundColor White
    Write-Host "     Go to: Foundation Central → Nodes (unconfigured)" -ForegroundColor Gray
    Write-Host "  3. Once nodes appear, resume the deployment pipeline:" -ForegroundColor White
    Write-Host "     .\Start-Pipeline.ps1 -ConfigFile $ConfigFile -StartAtStep <current step>" -ForegroundColor Gray
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
    exit 1
}
