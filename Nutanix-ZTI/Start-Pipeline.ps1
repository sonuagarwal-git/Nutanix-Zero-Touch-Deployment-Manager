#Requires -Version 7.0

<#
.SYNOPSIS
    Orchestrate the full Nutanix ZTD pipeline — image, create cluster, and post-config.
.DESCRIPTION
    Runs a sequence of scripts in order. Each step must exit with code 0 (success) before
    the next step is started. If any step fails, the pipeline halts immediately and the
    remaining steps are skipped.

    Between each step a configurable delay is applied (default: 60 s). A live countdown
    timer shows the remaining wait time so the operator always knows what is happening.

    Pipeline steps (edit the $Pipeline array below to customise):
      1. Phonix-Boot.ps1                            — Mount Phoenix ISO via iLO and reboot nodes
      2. Phoonix-Boot-Check.ps1                     — Wait until all nodes have booted into Phoenix OS
      3. Node-Discover-Check.ps1                    — Poll Foundation Central until all nodes are discovered
      4. Image-And-Deploy-Cluster.ps1              — Image nodes and create cluster via Foundation Central
      5. Accept-NutanixEULA.ps1                     — Accept EULA on Prism Element
      6. Register-to-Witness.ps1                    — Register cluster to Witness VM
      7. Register-to-PC.ps1                         — Register cluster to Prism Central
      8. Create-Nutanix-vLAN.ps1                    — Create production VLANs
      9. Create-Nutanix-Storage-Container.ps1       — Create storage container
     10. Manage-PC-Backup-Policies-WithCategories   — Create/update PC backup policies
     11. Manage-Protection-Policy-With-Category     — Create/update failover protection policy
     12. Manage-Recovery-Plan-With-Category         — Create/update failover recovery plan
     13. Set-Nutanix-VSwitch-Bond-Mode.ps1             — Configure OVS bond mode on all AHV nodes
     14. Change-Prism-CVM-AHV-Password-ToCSV.ps1   — Rotate all passwords and export to CSV
     15. Import-Secrets-to-CyberArk.ps1             — Import new passwords into CyberArk SecureVault

.PARAMETER ConfigFile
    Path to the deployment JSON config (same file used by Deploy-Imaging and CreateCluster).
    Values such as cluster_vip, prism_central/foundation_central credentials, and
    storage_container_name are read automatically and passed to each step.

.PARAMETER DryRun
    Runs a full pre-flight validation against the config file WITHOUT executing any pipeline
    steps. Checks: Prism Central credentials & connectivity, iLO access per node, DNS
    reachability, NTP reachability, IP addresses free (Cluster VIP / Data Service IP / Hypervisor / CVM),
    ISO and package URL accessibility, and CyberArk API access.

.PARAMETER StartAtStep
    Step number (1-based) to start from. Use this to resume after a partial failure
    without re-running already-completed steps. Default: 1.

.PARAMETER WhatIf
    Preview the full pipeline plan without executing any scripts.

.EXAMPLE
    .\Start-Pipeline.ps1 -ConfigFile .\Configs\my-cluster.json
    Run the full pipeline for my-cluster.

.EXAMPLE
    .\Start-Pipeline.ps1 -ConfigFile .\Configs\my-cluster.json -WhatIf
    Preview the pipeline without executing anything.

.EXAMPLE
    .\Start-Pipeline.ps1 -ConfigFile .\Configs\my-cluster.json -DryRun
    Validate imaging + cluster creation without making any changes.
    Steps without DryRun support run normally.

.EXAMPLE
    .\Start-Pipeline.ps1 -ConfigFile .\Configs\my-cluster.json -StartAtStep 5
    Skip Phoenix Boot steps — resume from Accept-EULA.

.NOTES
    Author: Sonu Agarwal
    Date: May 25, 2026
    Version: 1.0
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ConfigFile,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [ValidateRange(1, 99)]
    [int]$StartAtStep = 1,

    # Comma-separated step numbers to skip during execution, e.g. "7,9"
    [Parameter()]
    [string]$SkipSteps = '',

    # Skip the pre-flight gate entirely (use when IPs are known-good stale entries)
    [Parameter()]
    [switch]$SkipPreCheck,

    # Email address of the person who triggered the pipeline (passed by the web app).
    # Used as the To address for the result email. If empty, email is skipped.
    [Parameter()]
    [string]$TriggeredBy = '',

    # Optional CC addresses (comma-separated). Passed from notify.cc in the cluster config.
    [Parameter()]
    [string]$Cc = ''
)

#region ── Constants ───────────────────────────────────────────────────────────
$MaxLogFiles   = 5
$LogsDirectory = Join-Path $PSScriptRoot 'Logs'
#endregion

# Force UTF-8 output and ANSI colour codes when running piped from Node.js.
# Without these, PowerShell strips colours (OutputRendering=Host) and encodes
# output in the OEM codepage, turning Unicode symbols into garbage characters.
# $OutputEncoding controls bytes written to pipes; [Console]::OutputEncoding
# controls the console host. Both must be set for piped + interactive modes.
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
$PSStyle.OutputRendering  = 'Ansi'

# Parse user-requested step skips (e.g. -SkipSteps "7,9" or "7, 9")
$skipStepsArr = if ($SkipSteps.Trim()) {
    $SkipSteps -split ',' | ForEach-Object {
        $t = $_.Trim()
        if ($t -match '^\d+$') { [int]$t }
    }
} else { @() }

# SSL bypass (lab — self-signed certs on PC/PE)
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
$PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
$ErrorActionPreference = 'Stop'

# Catch any unhandled terminating error and send a FAILED email before exiting.
# This ensures the notification fires even if the script crashes before reaching
# the normal summary section (e.g. a null-ref during log init, an unexpected API
# exception during pre-flight, etc.).
trap {
    $errMsg = $_.Exception.Message
    Write-Host ""
    Write-Host "  ✗ Unhandled error: $errMsg" -ForegroundColor Red
    if ($script:PipelineLogFile) {
        Add-Content -Path $script:PipelineLogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [ERROR] Unhandled crash: $errMsg" -ErrorAction SilentlyContinue
    }
    $_emailScript = Join-Path $PSScriptRoot 'Send-PipelineEmail.ps1'
    if ((Test-Path $_emailScript) -and $clusterName) {
        try {
            & $_emailScript `
                -ClusterName $clusterName `
                -Status      'FAILED' `
                -FailedStep  "Script crashed: $errMsg" `
                -StepResults ($results ?? @()) `
                -LogFile     ($script:PipelineLogFile ?? '')
        } catch { }
    }
    exit 1
}

#region ── Helpers ─────────────────────────────────────────────────────────────

$script:PipelineLogFile = $null

function Write-PipelineLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    if ($script:PipelineLogFile) {
        Add-Content -Path $script:PipelineLogFile -Value $line -ErrorAction SilentlyContinue
    }
}

function Write-Banner {
    param([string]$Text, [string]$Color = 'Cyan')
    $width = 65
    $line  = '═' * $width
    Write-Host ""
    Write-Host $line                    -ForegroundColor $Color
    Write-Host ("  {0}" -f $Text)       -ForegroundColor $Color
    Write-Host $line                    -ForegroundColor $Color
    Write-PipelineLog $Text
}

function Write-StepHeader {
    param([int]$Number, [int]$Total, [string]$Name)
    $bar = '─' * 65
    Write-Host ""
    Write-Host $bar -ForegroundColor DarkGray
    Write-Host ("  STEP {0}/{1}  ►  {2}" -f $Number, $Total, $Name) -ForegroundColor White
    Write-Host $bar -ForegroundColor DarkGray
    Write-PipelineLog ("STEP $Number/$Total : $Name")
}

function Write-Result {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
    Write-PipelineLog $Message -Level $(switch ($Color) {
        'Red'    { 'ERROR'   }
        'Yellow' { 'WARN'    }
        'Green'  { 'SUCCESS' }
        default  { 'INFO'    }
    })
}

function Invoke-Countdown {
    param([int]$Seconds, [string]$Reason = 'before next step')
    if ($Seconds -le 0) { return }
    $msg = "  Waiting {0}s {1} ..." -f $Seconds, $Reason
    Write-Host ""
    Write-Host $msg -ForegroundColor DarkGray
    Write-PipelineLog ("Delay started: ${Seconds}s — $Reason")
    $elapsed  = 0
    $interval = 20
    while ($elapsed -lt $Seconds) {
        $sleepFor  = [Math]::Min($interval, $Seconds - $elapsed)
        Start-Sleep -Seconds $sleepFor
        $elapsed  += $sleepFor
        $remaining = $Seconds - $elapsed
        if ($remaining -gt 0) {
            $tick = "  ... {0}s remaining" -f $remaining
            Write-Host $tick -ForegroundColor DarkGray
            Write-PipelineLog ("Delay: ${remaining}s remaining")
        }
    }
    Write-Host "  Delay complete." -ForegroundColor DarkGray
    Write-PipelineLog ("Delay of ${Seconds}s completed")
}

function Invoke-LogRotation {
    param([string]$Directory, [string]$Pattern, [int]$Max = 5)
    try {
        Get-ChildItem -Path $Directory -Filter $Pattern -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $Max |
            ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Invoke-PreFlightChecks {
    param(
        [object]$Config,
        [string]$ConfigPath,
        [switch]$ExitOnFail   # $true in DryRun mode (exits); $false in pipeline guard (returns fail count)
    )

    $script:checkPass   = 0
    $script:checkWarn   = 0
    $script:checkFail   = 0
    $script:suggestions = [System.Collections.Generic.List[PSCustomObject]]::new()

    function Write-Check {
        param(
            [string]$Label,
            [string]$Status,
            [string]$Detail     = '',
            [string]$Suggestion = ''
        )
        $padded = $Label.PadRight(58)
        switch ($Status) {
            'PASS' {
                Write-Host "  ✓ $padded $Detail" -ForegroundColor Green
                $script:checkPass++
            }
            'WARN' {
                Write-Host "  ⚠ $padded $Detail" -ForegroundColor Yellow
                $script:checkWarn++
                if ($Suggestion) {
                    $script:suggestions.Add([PSCustomObject]@{ Status = 'WARN'; Label = $Label; Detail = $Detail; Action = $Suggestion })
                }
            }
            'FAIL' {
                Write-Host "  ✗ $padded $Detail" -ForegroundColor Red
                $script:checkFail++
                if ($Suggestion) {
                    $script:suggestions.Add([PSCustomObject]@{ Status = 'FAIL'; Label = $Label; Detail = $Detail; Action = $Suggestion })
                }
            }
        }
        Write-PipelineLog "$Status  $Label  $Detail"
    }

    $modeLabel = if ($ExitOnFail) { 'DryRun Mode' } else { 'Pre-Flight Gate' }
    Write-Banner "PRE-FLIGHT CHECKS — $modeLabel"
    Write-Host "  Config  : $ConfigPath" -ForegroundColor Gray
    Write-Host "  Cluster : $($Config.clusterName)" -ForegroundColor Gray
    Write-Host ""

    # ── 1. Prism Central ────────────────────────────────────────────────────────
    Write-Host '  ── Prism Central Accessibility Check ───────────────────────────────────────────────' -ForegroundColor DarkCyan
    $pcUrl  = $Config.prism_central.url
    $pcUser = $Config.prism_central.username
    $pcPass = $Config.prism_central.password
    $pcIP   = if ($pcUrl -match 'https?://([^:/]+)') { $Matches[1] } else { $null }

    if ($pcIP) {
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $ar  = $tcp.BeginConnect($pcIP, 9440, $null, $null)
            $ok  = $ar.AsyncWaitHandle.WaitOne(3000)
            $tcp.Close()
            if ($ok) {
                Write-Check "Prism Central port 9440 ($pcIP)" 'PASS'
            } else {
                Write-Check "Prism Central port 9440 ($pcIP)" 'FAIL' 'Connection timeout' `
                    -Suggestion "Verify PC is running and reachable at $pcIP. Check that firewall rules allow TCP/9440 from this host."
            }
        } catch {
            Write-Check "Prism Central port 9440 ($pcIP)" 'FAIL' $_.Exception.Message `
                -Suggestion "Check network connectivity to $pcIP and confirm the PC VM is powered on."
        }
    }

    try {
        $b64  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${pcUser}:${pcPass}"))
        $hdrs = @{ Authorization = "Basic $b64"; 'Content-Type' = 'application/json' }
        Invoke-RestMethod -Uri "$pcUrl/api/nutanix/v3/clusters/list" -Method POST -Headers $hdrs `
            -Body '{"kind":"cluster","length":1}' -SkipCertificateCheck -TimeoutSec 15 -ErrorAction Stop | Out-Null
        Write-Check "Prism Central REST API credentials" 'PASS' "($pcUser@$pcIP)"
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 401) {
            Write-Check "Prism Central REST API credentials" 'FAIL' 'Invalid credentials (HTTP 401)' `
                -Suggestion "Update 'prism_central.username' and/or 'prism_central.password' in the config file."
        } else {
            Write-Check "Prism Central REST API credentials" 'FAIL' $_.Exception.Message `
                -Suggestion "PC may still be booting or unreachable. Confirm port 9440 is open first, then retry."
        }
    }
    Write-Host ""

    # ── 2. iLO Accessibility ────────────────────────────────────────────────────
    Write-Host '  ── iLO Accessibility Check ──────────────────────────────────────────────────' -ForegroundColor DarkCyan
    foreach ($node in $Config.network.nodes) {
        $iloIp   = $node.iLO_ip
        $iloUser = $node.iLO_username
        $iloPwd  = $node.iLO_password
        $label   = "$($node.hostname) [$iloIp]"
        if (-not $iloIp -or -not $iloUser) {
            Write-Check "iLO $label" 'WARN' 'Missing iLO_ip or iLO_username in config' `
                -Suggestion "Add 'iLO_ip' and 'iLO_username' fields for node '$($node.hostname)' in network.nodes[]."
            continue
        }
        try {
            $body    = @{ UserName = $iloUser; Password = $iloPwd } | ConvertTo-Json -Compress
            $resp    = Invoke-WebRequest -Uri "https://$iloIp/redfish/v1/SessionService/Sessions/" `
                           -Method POST -Body $body -ContentType 'application/json' `
                           -SkipCertificateCheck -TimeoutSec 10 -ErrorAction Stop
            $token   = $resp.Headers['X-Auth-Token'] | Select-Object -First 1
            $sessLoc = $resp.Headers['Location']     | Select-Object -First 1
            if ($sessLoc -and $sessLoc -notmatch '^https?://') { $sessLoc = "https://$iloIp$sessLoc" }
            Write-Check "iLO $label" 'PASS' 'Redfish session created'
            if ($sessLoc) {
                try { Invoke-RestMethod -Uri $sessLoc -Method DELETE `
                          -Headers @{'X-Auth-Token'=$token} -SkipCertificateCheck -EA SilentlyContinue | Out-Null
                } catch {}
            }
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -eq 401) {
                Write-Check "iLO $label" 'FAIL' 'Invalid credentials (HTTP 401)' `
                    -Suggestion "Update 'iLO_username' and/or 'iLO_password' for node '$($node.hostname)' in the config file."
            } else {
                Write-Check "iLO $label" 'FAIL' $_.Exception.Message `
                    -Suggestion "Verify iLO IP '$iloIp' is correct in config and that iLO is powered on and accessible."
            }
        }
    }
    Write-Host ""

    # ── 3. DNS Servers ──────────────────────────────────────────────────────────
    Write-Host '  ── DNS Servers Reachability Check ─────────────────────────────────────────' -ForegroundColor DarkCyan
    foreach ($dns in $Config.dns_servers) {
        if (-not $dns) { continue }
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $ar  = $tcp.BeginConnect($dns, 53, $null, $null)
            $ok  = $ar.AsyncWaitHandle.WaitOne(2000)
            $tcp.Close()
            if ($ok) {
                Write-Check "DNS $dns (TCP/53)" 'PASS'
            } else {
                $ping = Test-Connection -ComputerName $dns -Count 1 -Quiet -EA SilentlyContinue
                if ($ping) {
                    Write-Check "DNS $dns (ICMP)" 'WARN' 'Port 53 timeout but host responds to ping' `
                        -Suggestion "DNS server $dns is reachable but TCP/53 timed out. Check firewall rules for DNS traffic."
                } else {
                    Write-Check "DNS $dns" 'FAIL' 'Unreachable on TCP/53 and ICMP' `
                        -Suggestion "Verify DNS server IP '$dns' in config is correct and that the server is running."
                }
            }
        } catch {
            Write-Check "DNS $dns" 'FAIL' $_.Exception.Message `
                -Suggestion "Verify DNS server IP '$dns' in config is correct and that the server is running."
        }
    }
    Write-Host ""

    # ── 4. NTP Servers ──────────────────────────────────────────────────────────
    Write-Host '  ── NTP Servers Reachability Check ────────────────────────────────────────' -ForegroundColor DarkCyan
    foreach ($ntp in $Config.ntp_servers) {
        if (-not $ntp) { continue }
        $ping = Test-Connection -ComputerName $ntp -Count 1 -Quiet -EA SilentlyContinue
        if ($ping) {
            Write-Check "NTP $ntp (ICMP)" 'PASS'
        } else {
            try {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                $ar  = $tcp.BeginConnect($ntp, 123, $null, $null)
                $ok  = $ar.AsyncWaitHandle.WaitOne(2000)
                $tcp.Close()
                if ($ok) {
                    Write-Check "NTP $ntp (TCP/123)" 'PASS'
                } else {
                    Write-Check "NTP $ntp" 'WARN' 'No ICMP or TCP/123 response — NTP uses UDP, verify manually' `
                        -Suggestion "NTP uses UDP/123 which cannot be TCP-tested. Confirm '$ntp' is reachable and running NTP (e.g. w32tm /stripchart /computer:$ntp)."
                }
            } catch {
                Write-Check "NTP $ntp" 'WARN' 'No ICMP response — NTP uses UDP, verify manually' `
                    -Suggestion "Confirm NTP server '$ntp' is running (e.g. w32tm /stripchart /computer:$ntp). Check firewall for UDP/123."
            }
        }
    }
    Write-Host ""

    # ── 5. IP Addresses Free ────────────────────────────────────────────────────
    Write-Host '  ── IP Addresses (should be free) ──────────────────────────────────────' -ForegroundColor DarkCyan
    $ipsToCheck = [System.Collections.Generic.List[object]]::new()
    if ($Config.network.cluster_vip) {
        $ipsToCheck.Add([PSCustomObject]@{ IP = $Config.network.cluster_vip; Label = 'Cluster VIP' })
    }
    if ($Config.network.PSObject.Properties['data_service_ip'] -and $Config.network.data_service_ip) {
        $ipsToCheck.Add([PSCustomObject]@{ IP = $Config.network.data_service_ip; Label = 'Data Service IP' })
    }
    foreach ($node in $Config.network.nodes) {
        if ($node.hypervisor_ip) { $ipsToCheck.Add([PSCustomObject]@{ IP = $node.hypervisor_ip; Label = "AHV  $($node.hostname)" }) }
        if ($node.cvm_ip)        { $ipsToCheck.Add([PSCustomObject]@{ IP = $node.cvm_ip;        Label = "CVM  $($node.hostname)" }) }
    }
    $ipsInUse = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $ipsToCheck) {
        $inUse = Test-Connection -ComputerName $entry.IP -Count 1 -Quiet -EA SilentlyContinue
        if ($inUse) {
            Write-Check "$($entry.Label) $($entry.IP)" 'FAIL' 'IP is responding — already in use!'
            $ipsInUse.Add("$($entry.IP) ($($entry.Label))")
        } else {
            Write-Check "$($entry.Label) $($entry.IP)" 'PASS' 'Free'
        }
    }
    if ($ipsInUse.Count -gt 0) {
        $ipList = $ipsInUse -join ', '
        $script:suggestions.Add([PSCustomObject]@{
            Status = 'FAIL'
            Label  = 'IP Addresses in use'
            Detail = "$($ipsInUse.Count) IP(s) are responding: $ipList"
            Action = "These IPs are reachable, meaning they are in use. If you are sure they are not used by any other application and this is a stale entry from a previous run, use the 'Skip Pre-Check' button in the UI and retry. Otherwise decommission the existing devices or update the IPs in the config."
        })
    }
    Write-Host ""

    # ── 6. URL / ISO Accessibility ──────────────────────────────────────────────
    Write-Host '  ── URL / ISO Accessibility Check ────────────────────────────────────────────' -ForegroundColor DarkCyan
    $urls = [ordered]@{}
    if ($Config.aos_package_url)    { $urls['AOS Package URL']    = $Config.aos_package_url }
    if ($Config.hypervisor_iso_url) { $urls['Hypervisor ISO URL'] = $Config.hypervisor_iso_url }
    if ($Config.phoenix_iso_url)    { $urls['Phoenix ISO URL']    = $Config.phoenix_iso_url }
    foreach ($kv in $urls.GetEnumerator()) {
        try {
            $r    = Invoke-WebRequest -Uri $kv.Value -Method HEAD -UseBasicParsing `
                        -TimeoutSec 20 -SkipCertificateCheck -ErrorAction Stop
            $size = $r.Headers['Content-Length'] | Select-Object -First 1
            $mb   = if ($size) { "$([math]::Round([int64]$size / 1MB, 1)) MB" } else { 'size unknown' }
            Write-Check $kv.Key 'PASS' $mb
        } catch {
            Write-Check $kv.Key 'FAIL' $_.Exception.Message `
                -Suggestion "Verify the '$($kv.Key)' URL in the config is correct. Confirm the file server is running and the path exists. Try opening the URL manually: $($kv.Value)"
        }
    }
    Write-Host ""

    # ── 7. CyberArk ─────────────────────────────────────────────────────────────
    Write-Host '  ── CyberArk Access Check ───────────────────────────────────────────' -ForegroundColor DarkCyan
    if ($Config.cyberark -and $Config.cyberark.base_url) {
        $caUrl    = $Config.cyberark.base_url
        $caUser   = $Config.cyberark.username
        $caPass   = $Config.cyberark.password
        $caAnswer = $Config.cyberark.security_answer
        $caTenant = if ($Config.cyberark.tenant_id) { $Config.cyberark.tenant_id } else { '' }

        if (-not $caUser -or -not $caPass) {
            Write-Check 'CyberArk authentication' 'WARN' 'Missing username or password in config' `
                -Suggestion "Add 'cyberark.username' and 'cyberark.password' to the config file."
        } else {
            # Step 1 — StartAuthentication (read-only, just initiates session)
            $sessionId      = $null
            $pwMechanismId  = $null
            $sqMechanismId  = $null
            try {
                $saBody = @{ TenantId = $caTenant; Version = '1.0'; User = $caUser } | ConvertTo-Json -Compress
                $saResp = Invoke-WebRequest -Uri "$caUrl/Security/StartAuthentication" `
                              -Method POST -Body $saBody -ContentType 'application/json' `
                              -UseBasicParsing -TimeoutSec 15 -SkipCertificateCheck -ErrorAction Stop
                $sa     = $saResp.Content | ConvertFrom-Json
                if ($sa.success -eq $false) {
                    Write-Check 'CyberArk StartAuthentication' 'FAIL' $sa.Message `
                        -Suggestion "CyberArk rejected the session start. Verify 'cyberark.username' and 'cyberark.tenant_id' are correct in the config."
                } else {
                    Write-Check 'CyberArk StartAuthentication' 'PASS' "Session started ($caUser)"
                    $sessionId     = $sa.Result.SessionId
                    $pwMechanismId = $sa.Result.Challenges[0].Mechanisms[0].MechanismId
                    $sqMechanismId = $sa.Result.Challenges[1].Mechanisms[0].MechanismId
                }
            } catch {
                $errBody = $_.ErrorDetails.Message
                $detail  = if ($errBody) { $errBody } else { $_.Exception.Message }
                Write-Check 'CyberArk StartAuthentication' 'FAIL' $detail `
                    -Suggestion "Verify 'cyberark.base_url' is reachable and the username '$caUser' exists in the CyberArk tenant."
            }

            # Step 2 — Password challenge (only if Step 1 succeeded)
            if ($sessionId -and $pwMechanismId) {
                try {
                    $pwBody = @{ Action = 'Answer'; Answer = $caPass; SessionId = $sessionId; MechanismId = $pwMechanismId } | ConvertTo-Json -Compress
                    $pwResp = Invoke-WebRequest -Uri "$caUrl/Security/AdvanceAuthentication" `
                                  -Method POST -Body $pwBody -ContentType 'application/json' `
                                  -UseBasicParsing -TimeoutSec 15 -SkipCertificateCheck -ErrorAction Stop
                    $pw     = $pwResp.Content | ConvertFrom-Json
                    if ($pw.success -eq $false) {
                        Write-Check 'CyberArk password challenge' 'FAIL' $pw.Message `
                            -Suggestion "Update 'cyberark.password' in the config file — password was rejected by CyberArk."
                        $sessionId = $null   # don't attempt step 3
                    } else {
                        Write-Check 'CyberArk password challenge' 'PASS'
                    }
                } catch {
                    $errBody = $_.ErrorDetails.Message
                    $detail  = if ($errBody) { $errBody } else { $_.Exception.Message }
                    Write-Check 'CyberArk password challenge' 'FAIL' $detail `
                        -Suggestion "Update 'cyberark.password' in the config file."
                    $sessionId = $null
                }
            }

            # Step 3 — Security question challenge (only if Step 2 succeeded)
            if ($sessionId -and $sqMechanismId) {
                try {
                    $sqBody = @{ Action = 'Answer'; Answer = $caAnswer; SessionId = $sessionId; MechanismId = $sqMechanismId } | ConvertTo-Json -Compress
                    $sqResp = Invoke-WebRequest -Uri "$caUrl/Security/AdvanceAuthentication" `
                                  -Method POST -Body $sqBody -ContentType 'application/json' `
                                  -UseBasicParsing -TimeoutSec 15 -SkipCertificateCheck -ErrorAction Stop
                    $sq     = $sqResp.Content | ConvertFrom-Json
                    if ($sq.success -eq $false) {
                        Write-Check 'CyberArk security answer' 'FAIL' $sq.Message `
                            -Suggestion "Update 'cyberark.security_answer' in the config file — security question answer was rejected."
                    } else {
                        $hasToken = [bool]$sq.Result.Token
                        if ($hasToken) {
                            Write-Check 'CyberArk security answer' 'PASS' 'Full authentication successful — token obtained'
                        } else {
                            Write-Check 'CyberArk security answer' 'WARN' 'Challenge passed but no token returned' `
                                -Suggestion "Auth flow completed but no token was issued. Verify the service account is not locked and has Privileged Cloud access."
                        }
                    }
                } catch {
                    $errBody = $_.ErrorDetails.Message
                    $detail  = if ($errBody) { $errBody } else { $_.Exception.Message }
                    Write-Check 'CyberArk security answer' 'FAIL' $detail `
                        -Suggestion "Update 'cyberark.security_answer' in the config file."
                }
            }
        }
    } else {
        Write-Check 'CyberArk' 'WARN' 'No cyberark section in config — skipped' `
            -Suggestion "Add a 'cyberark' section to the config with base_url, username, password, security_answer, and tenant_id."
    }
    Write-Host ""

    # ── 8. Witness Server ───────────────────────────────────────────────────────
    if ($Config.witness -and $Config.witness.ip) {
        Write-Host '  ── Witness Server Reachability Check ───────────────────────────────────' -ForegroundColor DarkCyan
        $wIP   = $Config.witness.ip
        $wUser = $Config.witness.username
        $wPass = $Config.witness.password
        $wName = if ($Config.witness.name) { $Config.witness.name } else { $wIP }

        # Step 1: ping
        $wPing = Test-Connection -ComputerName $wIP -Count 1 -Quiet -EA SilentlyContinue
        if (-not $wPing) {
            Write-Check "Witness $wName" 'FAIL' "No ICMP response from $wIP" `
                -Suggestion "Witness VM '$wName' ($wIP) is unreachable. Verify the VM is powered on and the IP is correct in the config."
        } else {
            Write-Check "Witness $wName ping" 'PASS' "$wIP reachable"

            # Step 2: SSH credential validation
            if ($wUser -and $wPass) {
                try {
                    if (-not (Get-Module -Name Posh-SSH -EA SilentlyContinue)) {
                        Import-Module Posh-SSH -ErrorAction Stop
                    }
                    $wSecure  = ConvertTo-SecureString $wPass -AsPlainText -Force
                    $wCred    = New-Object System.Management.Automation.PSCredential($wUser, $wSecure)
                    $wSession = New-SSHSession -ComputerName $wIP -Credential $wCred -AcceptKey -Force -Port 22 -ErrorAction Stop -WarningAction SilentlyContinue 3>$null
                    Remove-SSHSession -SessionId $wSession.SessionId | Out-Null
                    Write-Check "Witness $wName SSH" 'PASS' "SSH authenticated ($wUser@$wIP)"
                } catch {
                    $errMsg = $_.Exception.Message
                    if ($errMsg -match 'Auth|password|denied|Permission') {
                        Write-Check "Witness $wName SSH" 'FAIL' "SSH authentication failed — wrong username/password" `
                            -Suggestion "Update 'witness.username' and 'witness.password' in the config for witness VM '$wName' ($wIP)."
                    } else {
                        Write-Check "Witness $wName SSH" 'WARN' "SSH connection failed: $errMsg" `
                            -Suggestion "Verify Witness VM '$wName' ($wIP) allows SSH on port 22 and the firewall is open."
                    }
                }
            } else {
                Write-Check "Witness $wName SSH" 'WARN' 'No credentials in config — skipped' `
                    -Suggestion "Add 'witness.username' and 'witness.password' to the config to enable SSH credential verification."
            }
        }
        Write-Host ""
    }

    # ── 9. Backup Policy Config Completeness ────────────────────────────────────
    if ($Config.backup_policy) {
        Write-Host '  ── Backup Policy Configuration ─────────────────────────────────────────' -ForegroundColor DarkCyan
        $bkErrors = @()
        if (-not $Config.backup_policy.remote_cluster_name) {
            $bkErrors += 'backup_policy.remote_cluster_name is required but not set'
        }
        $policyPresent = $Config.backup_policy.hourly -or $Config.backup_policy.daily -or $Config.backup_policy.weekly -or $Config.backup_policy.monthly
        if (-not $policyPresent) {
            $bkErrors += 'At least one policy (hourly/daily/weekly/monthly) must be configured under backup_policy'
        }
        $policyRawMap = @{
            hourly  = @{ cfg = $Config.backup_policy.hourly;   rpo = 'rpo_hours' }
            daily   = @{ cfg = $Config.backup_policy.daily;    rpo = 'rpo_hours' }
            weekly  = @{ cfg = $Config.backup_policy.weekly;   rpo = 'rpo_days'  }
            monthly = @{ cfg = $Config.backup_policy.monthly;  rpo = 'rpo_days'  }
        }
        foreach ($type in $policyRawMap.Keys) {
            $raw = $policyRawMap[$type]
            if (-not $raw.cfg) { continue }
            $p   = $raw.cfg
            $rpo = $raw.rpo
            if (-not $p.name)             { $bkErrors += "backup_policy.$type.name is required" }
            if (-not $p.$rpo)             { $bkErrors += "backup_policy.$type.$rpo is required" }
            if (-not $p.local_retention)  { $bkErrors += "backup_policy.$type.local_retention is required" }
            if (-not $p.remote_retention) { $bkErrors += "backup_policy.$type.remote_retention is required" }
            if (-not $p.category_key)     { $bkErrors += "backup_policy.$type.category_key is required" }
            if (-not $p.category_value)   { $bkErrors += "backup_policy.$type.category_value is required" }
        }
        if ($bkErrors.Count -gt 0) {
            foreach ($err in $bkErrors) {
                Write-Check "Backup config: $err" 'FAIL' $err `
                    -Suggestion "Fix '$err' in the config file before running the pipeline."
            }
        } else {
            $policyNames = @('hourly','daily','weekly','monthly') | Where-Object { $Config.backup_policy.$_ } | ForEach-Object { $_ }
            Write-Check 'Backup config' 'PASS' "remote_cluster_name='$($Config.backup_policy.remote_cluster_name)', policies: $($policyNames -join ', ')"
        }
        Write-Host ""
    }

    # ── 10. Protection Policy Config Completeness ────────────────────────────────
    if ($Config.protection_policy) {
        Write-Host '  ── Protection Policy Configuration ─────────────────────────────────────' -ForegroundColor DarkCyan
        $ppErrors = @()
        $pp = $Config.protection_policy
        if (-not $pp.remote_cluster_name) { $ppErrors += 'protection_policy.remote_cluster_name is required' }
        if (-not $pp.name)                { $ppErrors += 'protection_policy.name is required' }
        if (-not $pp.rpo_hours)           { $ppErrors += 'protection_policy.rpo_hours is required' }
        if (-not $pp.local_retention)     { $ppErrors += 'protection_policy.local_retention is required' }
        if (-not $pp.remote_retention)    { $ppErrors += 'protection_policy.remote_retention is required' }
        if (-not $pp.category_key)        { $ppErrors += 'protection_policy.category_key is required' }
        if (-not $pp.category_value)      { $ppErrors += 'protection_policy.category_value is required' }
        if ($ppErrors.Count -gt 0) {
            foreach ($err in $ppErrors) {
                Write-Check "Protection policy config: $err" 'FAIL' $err `
                    -Suggestion "Fix '$err' in the config file before running the pipeline."
            }
        } else {
            Write-Check 'Protection policy config' 'PASS' "remote_cluster_name='$($pp.remote_cluster_name)', policy='$($pp.name)'"
        }
        Write-Host ""
    }

    # ── 11. Recovery Plan Config Completeness ────────────────────────────────────
    if ($Config.recovery_plan) {
        Write-Host '  ── Recovery Plan Configuration ──────────────────────────────────────────' -ForegroundColor DarkCyan
        $rpErrors = @()
        $tgtNet   = $Config.recovery_plan.target_network
        if (-not $tgtNet) {
            $rpErrors += 'recovery_plan.target_network section is required'
        } else {
            if (-not $tgtNet.subnet_name)   { $rpErrors += 'recovery_plan.target_network.subnet_name is required' }
            if (-not $tgtNet.gateway)        { $rpErrors += 'recovery_plan.target_network.gateway is required' }
            if (-not $tgtNet.prefix_length)  { $rpErrors += 'recovery_plan.target_network.prefix_length is required' }
            if (-not $tgtNet.ip_pool_start)  { $rpErrors += 'recovery_plan.target_network.ip_pool_start is required' }
            if (-not $tgtNet.ip_pool_end)    { $rpErrors += 'recovery_plan.target_network.ip_pool_end is required' }
        }
        if ($rpErrors.Count -gt 0) {
            foreach ($err in $rpErrors) {
                Write-Check "Recovery plan config: $err" 'FAIL' $err `
                    -Suggestion "Fix '$err' in the config file before running the pipeline."
            }
        } else {
            Write-Check 'Recovery plan config' 'PASS' "target_network='$($tgtNet.subnet_name)' ($($tgtNet.gateway)/$($tgtNet.prefix_length))"
        }
        Write-Host ""
    }

    # ── Summary ─────────────────────────────────────────────────────────────────
    $line = '═' * 72
    $resultColor = if ($script:checkFail -gt 0) { 'Red' } elseif ($script:checkWarn -gt 0) { 'Yellow' } else { 'Green' }

    Write-Host $line -ForegroundColor $resultColor
    Write-Host ("  PRE-FLIGHT SUMMARY   ✓ Pass: {0}   ⚠ Warn: {1}   ✗ Fail: {2}" -f `
        $script:checkPass, $script:checkWarn, $script:checkFail) -ForegroundColor $resultColor
    Write-Host $line -ForegroundColor $resultColor
    Write-PipelineLog "Pre-flight summary: Pass=$($script:checkPass) Warn=$($script:checkWarn) Fail=$($script:checkFail)"

    # ── Suggested Actions ────────────────────────────────────────────────────────
    if ($script:suggestions.Count -gt 0) {
        Write-Host ""
        Write-Host '  ── Suggested Actions ──────────────────────────────────────────────────' -ForegroundColor DarkCyan
        $i = 1
        foreach ($s in $script:suggestions) {
            $statusColor = if ($s.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
            $icon        = if ($s.Status -eq 'FAIL') { '✗' } else { '⚠' }
            Write-Host ""
            Write-Host "  [$i] $icon $($s.Label)" -ForegroundColor $statusColor
            if ($s.Detail) {
                Write-Host "      Problem : $($s.Detail)" -ForegroundColor DarkGray
            }
            Write-Host "      Action  : $($s.Action)" -ForegroundColor White
            Write-PipelineLog "Suggestion [$i]: $($s.Label) — $($s.Action)"
            $i++
        }
        Write-Host ""
    }

    if ($script:checkFail -gt 0) {
        if ($ExitOnFail) {
            Write-Host "  Fix all $($script:checkFail) failed check(s) above, then re-run -DryRun to confirm before starting the pipeline." -ForegroundColor Red
            exit 1
        } else {
            Write-Host "  ✗ $($script:checkFail) failed check(s) — pipeline will NOT start. Resolve the issues above and retry." -ForegroundColor Red
            return $script:checkFail
        }
    }
    Write-Host "  ✓ All critical checks passed." -ForegroundColor Green
    if ($script:checkWarn -gt 0) {
        Write-Host "  ⚠ $($script:checkWarn) warning(s) noted above — review before running the pipeline." -ForegroundColor Yellow
    }
    if ($ExitOnFail) { exit 0 } else { return 0 }
}

#region ── Load & validate config ──────────────────────────────────────────────

$configPath = if ([System.IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile
} else {
    Join-Path $PSScriptRoot $ConfigFile
}

if (-not (Test-Path $configPath)) {
    Write-Host "  ✗ Config file not found: $configPath" -ForegroundColor Red
    exit 1
}

try {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
} catch {
    Write-Host "  ✗ Failed to parse config JSON: $_" -ForegroundColor Red
    exit 1
}

# Resolve PC credentials
$pcSection = $cfg.prism_central
if (-not $pcSection) {
    Write-Host "  ✗ Config missing 'prism_central' section" -ForegroundColor Red
    exit 1
}

$clusterVip    = $cfg.network.cluster_vip
$pcPassword    = $pcSection.password
$clusterName   = $cfg.clusterName
$nodeCount     = if ($cfg.network.nodes) { @($cfg.network.nodes).Count } else { 0 }

# Merge notify.to / notify.cc from config into pipeline email params.
# Config values are used as fallback when the web app does not pass them as parameters.
# If both exist, they are merged (comma-separated) so no address is lost.
if ($cfg.notify -and $cfg.notify.to) {
    if ($TriggeredBy) {
        # Both provided — merge so both addresses receive the email
        $TriggeredBy = ((@($TriggeredBy) + @($cfg.notify.to | Where-Object { $_ -ne $TriggeredBy })) -join ',')
    } else {
        $TriggeredBy = $cfg.notify.to
    }
}
if ($cfg.notify -and $cfg.notify.cc) {
    if ($Cc) {
        # Merge config CC with any CC passed from web app, deduplicating
        $allCcAddresses = (@($Cc -split ',') + @($cfg.notify.cc -split ',')) |
                          ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
        $Cc = $allCcAddresses -join ','
    } else {
        $Cc = $cfg.notify.cc
    }
}

#endregion

#region ── Pipeline definition ─────────────────────────────────────────────────
# Each step is a hashtable with:
#   Name          — Label shown in the UI
#   Script        — Absolute path (or $PSScriptRoot-relative) to the .ps1 file
#   Arguments     — Hashtable of named params splatted into the script call
#   SupportsDryRun — $true if the script accepts a -DryRun switch. When the
#                   pipeline is run with -DryRun, it is automatically added
#                   to Arguments for that step only.
#   DelaySeconds  — Optional settling time (seconds) AFTER this step's script exits.
#                   Set to 0 when the script already polls until completion (most cases).
#                   Useful if an API/service needs extra time to become ready after a task.
#
# To skip a step: comment it out or remove it from the array.
# To add a step: add a new hashtable following the same pattern.
# ─────────────────────────────────────────────────────────────────────────────

$Pipeline = @(

    @{
        Name           = 'Phoenix Boot — Mount ISO & Reboot'
        Script         = Join-Path $PSScriptRoot 'Phonix-Boot.ps1'
        SupportsDryRun = $false
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = 30
    },

    @{
        Name           = 'Phoenix Boot Check — Wait for Phoenix OS'
        Script         = Join-Path $PSScriptRoot 'Phoonix-Boot-Check.ps1'
        SupportsDryRun = $false
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = if ($nodeCount -ge 2) { 1200 } else { 900 }
    },

    @{
        Name           = 'Node Discovery Check — Foundation Central'
        Script         = Join-Path $PSScriptRoot 'Node-Discovery-Check.ps1'
        SupportsDryRun = $false
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = 30
    },

    @{
        Name           = 'Image & Deploy Cluster (Foundation Central)'
        Script         = Join-Path $PSScriptRoot 'Image-And-Deploy-Cluster.ps1'
        SupportsDryRun = $true
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = 60
    },

    @{
        Name           = 'Accept EULA (Prism Element)'
        Script         = Join-Path $PSScriptRoot 'Accept-EULA.ps1'
        SupportsDryRun = $false
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = 15
    },

    @{
        Name           = 'Register to Witness VM'
        Script         = Join-Path $PSScriptRoot 'Register-NewCluster-To-Witness.ps1'
        SupportsDryRun = $false
        Skip           = ($nodeCount -ne 2 -or -not ($cfg.witness -and $cfg.witness.ip))
        SkipReason     = if ($nodeCount -ne 2) { "Witness only required for 2-node clusters (config has $nodeCount node(s))" } else { "Witness not configured in config file" }
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = 15
    },

    @{
        Name           = 'Register Cluster to Prism Central'
        Script         = Join-Path $PSScriptRoot 'Register-NewCluster-To-PC.ps1'
        SupportsDryRun = $false
        Arguments      = @{
            ConfigFile = $configPath
        }
        # PC needs time to fully sync the new cluster's capabilities (RF, AOS version,
        # network config) before it can be used as a replication SOURCE in protection policies.
        # 60s is enough for the UUID to appear but not for full capability handshake.
        DelaySeconds   = 300
    },

    @{
        Name           = 'Create Production VLANs'
        Script         = Join-Path $PSScriptRoot 'Create-vLAN.ps1'
        SupportsDryRun = $false
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = 15
        Skip           = (-not ($cfg.production_vlans -and @($cfg.production_vlans).Count -gt 0))
        SkipReason     = 'Production VLANs not configured (production_vlans absent or empty in config)'
    },

    @{
        Name           = 'Create Storage Container'
        Script         = Join-Path $PSScriptRoot 'Create-Storage-Container.ps1'
        SupportsDryRun = $false
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = 15
        Skip           = ($cfg.storage_container.enabled -eq $false)
        SkipReason     = 'Storage container creation disabled in config (storage_container.enabled: false)'
    },

    @{
        Name           = 'Manage PC Backup Policies'
        Script         = Join-Path $PSScriptRoot 'Create-Backup-Policies-With-Categories.ps1'
        SupportsDryRun = $false
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = 15
        Skip           = (-not ($cfg.backup_policy -and $cfg.backup_policy.remote_cluster_name -and
                          ($cfg.backup_policy.hourly -or $cfg.backup_policy.daily -or $cfg.backup_policy.weekly -or $cfg.backup_policy.monthly)))
        SkipReason     = 'Backup policies not enabled in config file (backup section absent, remote_cluster_name not set, or no policy selected)'
    },

    @{
        Name           = 'Manage Protection Policy'
        Script         = Join-Path $PSScriptRoot 'Create-Protection-Policy-With-Category.ps1'
        SupportsDryRun = $false
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = 30
        Skip           = (-not ($cfg.protection_policy -and $cfg.protection_policy.remote_cluster_name -and $cfg.protection_policy.name))
        SkipReason     = 'Protection policy not enabled in config file (protection_policy section absent or required fields not set)'
    },

    @{
        Name           = 'Manage Recovery Plan'
        Script         = Join-Path $PSScriptRoot 'Create-Recovery-Plan-With-Category.ps1'
        SupportsDryRun = $false
        Arguments      = @{
            ConfigFile = $configPath
        }
        Skip           = (-not ($cfg.recovery_plan -and $cfg.recovery_plan.target_network -and
                          $cfg.recovery_plan.target_network.subnet_name))
        SkipReason     = 'Recovery plan not enabled in config file (recovery_plan section absent or target_network not configured)'
        DelaySeconds   = 15
    },

    @{
        Name           = 'Set vSwitch Bond Mode'
        Script         = Join-Path $PSScriptRoot 'Set-Nutanix-VSwitch-Bond-Mode.ps1'
        SupportsDryRun = $false
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = 30
    },

    @{
        Name           = 'Run LCM Inventory'
        Script         = Join-Path $PSScriptRoot 'Run-LCM-Inventory.ps1'
        SupportsDryRun = $false
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = 5
    },

    @{
        Name           = 'Change Passwords and Export to CSV'
        Script         = Join-Path $PSScriptRoot 'Change-Prism-CVM-AHV-Password.ps1'
        SupportsDryRun = $false
        Arguments      = @{
            ConfigFile = $configPath
            CsvFolder  = if ($cfg.cyberark.vault_folder) { $cfg.cyberark.vault_folder } else { 'Nutanix_Remote_Sites' }
        }
        DelaySeconds   = 15
    },

    @{
        Name           = 'Import Secrets to CyberArk'
        Script         = Join-Path $PSScriptRoot 'Import-Secrets-to-CyberArk.ps1'
        SupportsDryRun = $false
        Skip           = (-not ($cfg.cyberark -and $cfg.cyberark.base_url))
        SkipReason     = 'CyberArk not configured in config file'
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = 15
    },

    @{
        Name           = 'Add DNS Records'
        Script         = Join-Path $PSScriptRoot 'Add-DNS-Record.ps1'
        SupportsDryRun = $false
        Skip           = (-not ($cfg.dns_admin -and $cfg.dns_admin.username -and $cfg.dns_admin.password))
        SkipReason     = 'DNS admin credentials not configured in config file (dns_admin.username / dns_admin.password)'
        Arguments      = @{
            ConfigFile = $configPath
        }
        DelaySeconds   = 0
    }
)

#region ── Init unified run log ─────────────────────────────────────────────
# One log file per run — covers pre-flight, all 15 steps, and the summary.
# Replaces the old pipeline-*.txt, preflight-*.txt, and preflight-gate-*.txt files.

if (-not (Test-Path $LogsDirectory)) { New-Item -ItemType Directory -Path $LogsDirectory -Force | Out-Null }
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:PipelineLogFile = Join-Path $LogsDirectory "run-$clusterName-$ts.log"

$logHeader = @"
═══════════════════════════════════════════════════════════════
  Nutanix ZTD Pipeline Log
═══════════════════════════════════════════════════════════════
  Cluster   : $clusterName
  Config    : $configPath
  Started   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Total Steps: $($Pipeline.Count)
═══════════════════════════════════════════════════════════════
"@
Set-Content -Path $script:PipelineLogFile -Value $logHeader
Invoke-LogRotation -Directory $LogsDirectory -Pattern 'run-*.log' -Max $MaxLogFiles

# Thread the unified log path into the Image & Deploy step so deployment-log-*.txt is not created
$_imgStep = @($Pipeline | Where-Object { $_.Script -like '*Image-And-Deploy*' })[0]
if ($_imgStep) { $_imgStep.Arguments['LogFile'] = $script:PipelineLogFile }

#endregion

# ── DryRun mode: run pre-flight checks and exit ───────────────────────────
if ($DryRun) {
    Invoke-PreFlightChecks -Config $cfg -ConfigPath $configPath -ExitOnFail
    # Invoke-PreFlightChecks exits internally
}

# ── Deployment mode: run pre-flight checks as a safety gate ───────────────
# Steps 1-4 involve imaging/building — IPs must be free and environment clean.
# Steps 5+ run against a cluster already up; pre-flight checks are not meaningful.
if (-not $WhatIfPreference) {
    if ($SkipPreCheck) {
        Write-Host "  ⚠ Pre-flight checks SKIPPED by user request (-SkipPreCheck)." -ForegroundColor Yellow
        Write-Host "    Ensure the environment is healthy before proceeding." -ForegroundColor DarkGray
        Write-Host ""
    } elseif ($StartAtStep -ge 5) {
        Write-Host "  ℹ Pre-flight checks skipped (StartAtStep=$StartAtStep ≥ 5 — cluster already deployed)." -ForegroundColor DarkGray
        Write-Host ""
    } else {
        $failCount = Invoke-PreFlightChecks -Config $cfg -ConfigPath $configPath
        if ($failCount -gt 0) {
            Write-Host ""
            Write-Host "  Pipeline aborted — fix the $failCount failed pre-flight check(s) above and retry." -ForegroundColor Red
            Write-Host "  Tip: run with -DryRun to validate without starting the pipeline." -ForegroundColor DarkGray
            exit 1
        }
        Write-Host ""
        Write-Host "  ✓ Pre-flight gate passed — continuing to pipeline execution." -ForegroundColor Cyan
        Write-Host ""
    }
}

#endregion

#region ── WhatIf preview ──────────────────────────────────────────────────────

if ($WhatIfPreference) {
    $dryLabel = if ($DryRun) { ' + DryRun (CreateCluster only)' } else { '' }
    Write-Banner "PIPELINE PREVIEW — WhatIf mode (no scripts will run)$dryLabel" -Color Yellow
    Write-Host ("  Config : {0}" -f $configPath)         -ForegroundColor Gray
    Write-Host ("  Cluster: {0}  |  VIP: {1}" -f $clusterName, $clusterVip) -ForegroundColor Gray
    Write-Host ""
    $i = 0
    foreach ($step in $Pipeline) {
        $i++
        $skip   = $i -lt $StartAtStep
        $status = if ($skip) { '(SKIPPED — StartAtStep)' } else { '' }
        $color  = if ($skip) { 'DarkGray' } else { 'White' }
        Write-Host ("  [{0}] {1} {2}" -f $i, $step.Name, $status) -ForegroundColor $color
        foreach ($kv in $step.Arguments.GetEnumerator()) {
            Write-Host ("        -{0,-22} {1}" -f $kv.Key, $kv.Value) -ForegroundColor DarkGray
        }
        if ($DryRun) {
            if ($step.SupportsDryRun) {
                Write-Host ("        -{0,-22} {1}" -f 'DryRun', '$true  ← will be passed') -ForegroundColor Yellow
            } else {
                Write-Host ("        -{0,-22} {1}" -f 'DryRun', 'not supported — step runs normally') -ForegroundColor DarkGray
            }
        }
        if ($step.DelaySeconds -gt 0) {
            Write-Host ("        DelayAfter: {0}s" -f $step.DelaySeconds) -ForegroundColor DarkGray
        }
        Write-Host ""
    }
    exit 0
}

#endregion

#region ── Run pipeline ────────────────────────────────────────────────────────

$pipelineStart = Get-Date
$results       = [System.Collections.Generic.List[hashtable]]::new()

Write-Banner "Nutanix ZTD Pipeline  ·  $clusterName"
Write-Host ("  Config     : {0}" -f $configPath)                                    -ForegroundColor Gray
Write-Host ("  Cluster VIP: {0}" -f $clusterVip)                                    -ForegroundColor Gray
$skipInfo = if ($skipStepsArr.Count -gt 0) { "  |  skipping: $($skipStepsArr -join ', ')" } else { '' }
Write-Host ("  Steps      : {0}  (starting at step {1}{2})" -f $Pipeline.Count, $StartAtStep, $skipInfo) -ForegroundColor Gray
if ($DryRun) {
    Write-Host "  DryRun     : ON — only CreateCluster runs (validation only); all post-config steps are skipped" -ForegroundColor Yellow
}
Write-Host ("  Log        : {0}" -f $script:PipelineLogFile)                        -ForegroundColor Gray

$pipelineAborted = $false
$stepNumber      = 0

foreach ($step in $Pipeline) {
    $stepNumber++

    # ── Skip steps before StartAtStep
    if ($stepNumber -lt $StartAtStep) {
        $results.Add(@{ Step = $stepNumber; Name = $step.Name; Status = 'SKIPPED'; Duration = 'n/a' })
        Write-Host "`n  [Step $stepNumber/$($Pipeline.Count)] SKIPPED (StartAtStep=$StartAtStep)  ►  $($step.Name)" -ForegroundColor DarkGray
        Write-PipelineLog "SKIPPED: $($step.Name)"
        continue
    }

    # ── Skip steps explicitly requested by the user (-SkipSteps)
    if ($skipStepsArr -contains $stepNumber) {
        $results.Add(@{ Step = $stepNumber; Name = $step.Name; Status = 'SKIPPED (user)'; Duration = '0s' })
        Write-Host "`n  [Step $stepNumber/$($Pipeline.Count)] SKIPPED (user-requested)  ►  $($step.Name)" -ForegroundColor DarkYellow
        Write-PipelineLog "SKIPPED (user-requested): $($step.Name)"
        continue
    }

    Write-StepHeader -Number $stepNumber -Total $Pipeline.Count -Name $step.Name

    # ── Skip steps marked as not applicable
    if ($step.Skip) {
        $reason = if ($step.SkipReason) { $step.SkipReason } else { 'not applicable for this configuration' }
        Write-Result "  ⏭ Skipped — $reason" -Color DarkGray
        Write-PipelineLog "SKIPPED (not applicable): $($step.Name) — $reason"
        $results.Add(@{ Step = $stepNumber; Name = $step.Name; Status = 'SKIPPED (N/A)'; Duration = '0s' })
        continue
    }

    # Verify script exists
    $scriptPath = $step.Script
    if (-not (Test-Path $scriptPath)) {
        Write-Result "  ✗ Script not found: $scriptPath" -Color Red
        $results.Add(@{ Step = $stepNumber; Name = $step.Name; Status = 'FAILED (script not found)'; Duration = '0s' })
        $pipelineAborted = $true
        break
    }

    # ── Execute step ──────────────────────────────────────────────────────────
    # Inject -DryRun for steps that support it
    $stepArgs = $step.Arguments.Clone()
    if ($DryRun -and $step.SupportsDryRun) {
        $stepArgs['DryRun'] = $true
        Write-Result '  ℹ DryRun mode — passing -DryRun to this step' -Color Yellow
    } elseif ($DryRun -and -not $step.SupportsDryRun) {
        Write-Result '  ℹ DryRun mode — this step has no -DryRun support, running normally' -Color DarkGray
    }

    $stepStart  = Get-Date
    $stepFailed = $false

    # ANSI escape code pattern — stripped before writing to the log file so the
    # file is human-readable while the console / UI still receive full colour output.
    $ansiPattern = '\x1b\[[0-9;]*[mABCDEFGHJKSTfhilmnprsu]'

    try {
        & $scriptPath @stepArgs *>&1 | ForEach-Object {
            # Pass through to console (UI WebSocket captures this)
            $_
            # Convert to plain string safely — Format-Table and other cmdlets can emit
            # non-string formatting objects; calling Out-String on them individually
            # (outside their formatting sequence) throws "Operation is not valid...".
            $plain = try {
                if ($_ -is [string]) {
                    $_
                } elseif ($_ -is [System.Management.Automation.ErrorRecord]) {
                    $_.Exception.Message
                } else {
                    [string]$_
                }
            } catch { '' }
            $plain = $plain.TrimEnd() -replace $ansiPattern, ''
            if ($plain -and $script:PipelineLogFile) {
                Add-Content -Path $script:PipelineLogFile -Value $plain -ErrorAction SilentlyContinue
            }
        }
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 }
    } catch {
        Write-Result ("  ✗ Unhandled exception: {0}" -f $_.Exception.Message) -Color Red
        $exitCode = 1
    }

    $elapsed = [math]::Round(((Get-Date) - $stepStart).TotalSeconds)
    $durStr  = if ($elapsed -ge 60) { "{0}m {1}s" -f [int]($elapsed/60), ($elapsed % 60) } else { "${elapsed}s" }

    if ($exitCode -ne 0) {
        Write-Result ("  ✗ FAILED  (exit code {0}, elapsed {1})" -f $exitCode, $durStr) -Color Red
        $results.Add(@{ Step = $stepNumber; Name = $step.Name; Status = "FAILED (exit $exitCode)"; Duration = $durStr })
        $pipelineAborted = $true
        break
    }

    Write-Result ("  ✓ SUCCEEDED  (elapsed {0})" -f $durStr) -Color Green
    $results.Add(@{ Step = $stepNumber; Name = $step.Name; Status = 'OK'; Duration = $durStr })

    # ── Optional settling delay before next step
    if ($stepNumber -lt $Pipeline.Count -and $step.DelaySeconds -gt 0) {
        Invoke-Countdown -Seconds $step.DelaySeconds -Reason "settling time before next step"
    }
}

# Mark any remaining steps as skipped due to abort
if ($pipelineAborted) {
    for ($i = $stepNumber + 1; $i -le $Pipeline.Count; $i++) {
        $results.Add(@{ Step = $i; Name = $Pipeline[$i - 1].Name; Status = 'SKIPPED (pipeline aborted)'; Duration = 'n/a' })
        Write-PipelineLog "SKIPPED (aborted): $($Pipeline[$i - 1].Name)"
    }
}

#endregion

#region ── Summary ─────────────────────────────────────────────────────────────

$totalElapsed = [math]::Round(((Get-Date) - $pipelineStart).TotalSeconds)
$totalDurStr  = if ($totalElapsed -ge 60) { "{0}m {1}s" -f [int]($totalElapsed/60), ($totalElapsed % 60) } else { "${totalElapsed}s" }

Write-Banner "Pipeline Summary  ·  Total time: $totalDurStr" -Color $(if ($pipelineAborted) { 'Red' } else { 'Green' })

$colW  = 38
$durW  = 10
$statW = 30
$sepLine = "  {0}  {1}  {2}" -f ('-' * $colW), ('-' * $durW), ('-' * $statW)

Write-Host ("  {0,-$colW}  {1,-$durW}  {2}" -f 'Step', 'Duration', 'Status') -ForegroundColor White
Write-Host $sepLine -ForegroundColor DarkGray

foreach ($r in $results) {
    $color = switch -Wildcard ($r.Status) {
        'OK'               { 'Green'    }
        'FAILED*'          { 'Red'      }
        'SKIPPED*aborted*' { 'DarkGray' }
        'SKIPPED*'         { 'DarkGray' }
        default            { 'White'    }
    }
    $label = "[{0}] {1}" -f $r.Step, $r.Name
    Write-Host ("  {0,-$colW}  {1,-$durW}  {2}" -f $label, $r.Duration, $r.Status) -ForegroundColor $color
    Write-PipelineLog ("  Step {0}: {1} — {2}" -f $r.Step, $r.Name, $r.Status)
}

Write-Host ""

$overallStatus = if ($pipelineAborted) { 'FAILED' } else { 'SUCCESS' }
$failedStepName = ($results | Where-Object { $_.Status -like 'FAILED*' } | Select-Object -First 1).Name

if ($pipelineAborted) {
    Write-Host "  PIPELINE FAILED" -ForegroundColor Red
    Write-Host ("  Resume from the failed step with: -StartAtStep {0}" -f $stepNumber) -ForegroundColor Yellow
    Write-PipelineLog "PIPELINE FAILED at step $stepNumber"
} else {
    Write-Host "  PIPELINE COMPLETED SUCCESSFULLY" -ForegroundColor Green
    Write-PipelineLog "PIPELINE COMPLETED SUCCESSFULLY"
}

#region ── Send result email ───────────────────────────────────────────────────
$emailScript = Join-Path $PSScriptRoot 'Send-PipelineEmail.ps1'
if (Test-Path $emailScript) {
    Write-Host ""
    # Only include LCM data in the email if the LCM Inventory step actually ran (status OK)
    $lcmHtmlReport = ''
    $lcmStepResult = $results | Where-Object { $_.Name -eq 'Run LCM Inventory' } | Select-Object -First 1
    if ($lcmStepResult -and $lcmStepResult.Status -eq 'OK' -and
        $script:PipelineLogFile -and (Test-Path $script:PipelineLogFile)) {
        try {
            $logLines     = [System.IO.File]::ReadAllLines($script:PipelineLogFile, [System.Text.Encoding]::UTF8)
            $upgradeRows  = ''
            $upgradeCount = 0
            $inLcmSection = $false
            foreach ($line in $logLines) {
                # Enter the LCM section at the step INFO marker
                if ($line -match '\[INFO\]\s+STEP.*Run LCM Inventory') { $inLcmSection = $true; continue }
                # Exit the section at the timestamped SUCCESS/FAILED line that closes this step
                if ($inLcmSection -and $line -match '^\[20\d\d-.*\]\s+\[(SUCCESS|FAILED)\]') { break }

                # Only parse → lines while inside the LCM section
                if ($inLcmSection -and $line.Contains([char]0x2192)) {
                    $parts = $line -split [char]0x2192
                    if ($parts.Count -eq 2) {
                        $left   = $parts[0].Trim()
                        $target = $parts[1].Trim()
                        if ($left -match '^(.+?)\s{2,}(\S+)$') {
                            $comp    = $Matches[1].Trim() -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
                            $current = $Matches[2].Trim()
                            $upgradeRows += "<tr><td style='padding:6px 16px;border-bottom:1px solid #fde8e4'>$comp</td>" +
                                           "<td style='padding:6px 16px;border-bottom:1px solid #fde8e4;color:#999'>$current</td>" +
                                           "<td style='padding:6px 8px;border-bottom:1px solid #fde8e4;color:#bbb'>&rarr;</td>" +
                                           "<td style='padding:6px 16px;border-bottom:1px solid #fde8e4;color:#d84315;font-weight:600'>$target</td></tr>"
                            $upgradeCount++
                        }
                    }
                }
            }
            if ($upgradeCount -gt 0) {
                $lcmHtmlReport =
                    "<div style='margin:0 24px 20px;border-left:4px solid #e64a19;background:#fff8f5;padding:14px 16px;border-radius:0 4px 4px 0'>" +
                    "<p style='margin:0 0 10px;font-family:sans-serif;font-size:14px;font-weight:600;color:#bf360c'>" +
                    "&#9888;&nbsp; LCM Software Updates Available ($upgradeCount)</p>" +
                    "<table style='border-collapse:collapse;font-size:13px;width:100%'>" +
                    "<thead><tr style='background:#fbe9e7'>" +
                    "<th style='padding:6px 16px;text-align:left;font-family:sans-serif;color:#555;font-weight:600'>Component</th>" +
                    "<th style='padding:6px 16px;text-align:left;font-family:sans-serif;color:#555;font-weight:600'>Installed</th>" +
                    "<th style='padding:6px 8px'></th>" +
                    "<th style='padding:6px 16px;text-align:left;font-family:sans-serif;color:#555;font-weight:600'>Available</th>" +
                    "</tr></thead><tbody>$upgradeRows</tbody></table>" +
                    "<p style='margin:10px 0 0;font-size:12px;color:#888;font-family:sans-serif'>" +
                    "Upgrade order: Foundation &rarr; NCC &rarr; AOS &rarr; AHV</p></div>"
            }
        } catch {}
    }
    $emailArgs = @{
        ClusterName    = $clusterName
        Status         = $overallStatus
        Duration       = $totalDurStr
        StepResults    = $results
        LogFile        = $script:PipelineLogFile
        StartTime      = $pipelineStart
        EndTime        = (Get-Date)
        ClusterVip     = $clusterVip
        NodeCount      = @($cfg.network.nodes).Count
        LcmReportHtml  = $lcmHtmlReport
    }
    if ($failedStepName) { $emailArgs['FailedStep'] = $failedStepName }
    if ($TriggeredBy)    { $emailArgs['To'] = $TriggeredBy }
    if ($Cc)             { $emailArgs['Cc'] = $Cc }
    try {
        & $emailScript @emailArgs
    } catch {
        Write-Host "  ⚠ Email notification failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-PipelineLog "Email notification failed: $($_.Exception.Message)" -Level 'WARN'
    }
} else {
    Write-Host "  ⚠ Send-PipelineEmail.ps1 not found — skipping email notification." -ForegroundColor Yellow
}
#endregion

if ($pipelineAborted) { exit 1 } else { exit 0 }

#endregion
