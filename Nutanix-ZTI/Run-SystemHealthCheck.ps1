<#
.SYNOPSIS
    Run Nutanix NCC health checks on a cluster via SSH to a CVM.

.DESCRIPTION
    Connects to a CVM via SSH (Posh-SSH), runs 'ncc health_checks run_all' in
    the background, polls 'ecli task.list include_completed=false' until all NCC
    HealthCheck tasks finish, then retrieves and parses the NCC output log.

    Password resolution order (highest priority wins):
      1. -CvmPassword parameter
      2. <ClusterName>_Password.csv in the script folder (written by Step 15:
         Change-Prism-CVM-AHV-Password.ps1). Row: <ClusterName>_CVM_Nutanix,
         column 4 (space-delimited: Name Server Username Password Tags Folder Notes).
      3. health_check.cvm_password in the cluster JSON config file.
      4. Factory default: nutanix/4u

    Config file fields used:
      clusterName              — cluster name (for CSV lookup)
      network.cluster_vip      — SSH target when -CvmIP is not supplied
      health_check.cvm_password — optional password override

.PARAMETER ConfigFile
    Path to the cluster JSON config file. Optional when -CvmIP is supplied.

.PARAMETER ClusterName
    Cluster name. Used to locate the password CSV. Overrides the config file value.

.PARAMETER CvmIP
    IP or hostname of a CVM to SSH into (cluster VIP works).
    Falls back to network.cluster_vip from the config file.

.PARAMETER CvmUsername
    SSH username on the CVM. Default: nutanix.

.PARAMETER CvmPassword
    SSH password. When omitted the script resolves the password automatically —
    see the password resolution order in the Description.

.PARAMETER TaskTimeoutMinutes
    Maximum time to wait for the NCC run to complete. Default: 60 minutes.

.PARAMETER TaskPollSeconds
    Seconds between ecli task.list polls while NCC is running. Default: 20 seconds.

.EXAMPLE
    .\Run-SystemHealthCheck.ps1 -ConfigFile ".\Configs\my-cluster.json"

.EXAMPLE
    .\Run-SystemHealthCheck.ps1 -CvmIP "10.0.1.111" -ClusterName "SITE-1-CLUSTER"

.EXAMPLE
    .\Run-SystemHealthCheck.ps1 -ConfigFile ".\Configs\my-cluster.json" -CvmPassword "MyNewPass!"

.NOTES
    Requires: Posh-SSH module — Install-Module Posh-SSH -Scope CurrentUser
    Author:   Sonu Agarwal
    Date:     June 2026
    Version:  2.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string]$ConfigFile,
    [Parameter(Mandatory = $false)] [string]$ClusterName,
    [Parameter(Mandatory = $false)] [string]$CvmIP,
    [Parameter(Mandatory = $false)] [string]$CvmUsername        = 'nutanix',
    [Parameter(Mandatory = $false)] [string]$CvmPassword,
    [Parameter(Mandatory = $false)] [int]   $TaskTimeoutMinutes = 60,
    [Parameter(Mandatory = $false)] [int]   $TaskPollSeconds    = 20
)

$ErrorActionPreference = 'Stop'
$scriptDir             = $PSScriptRoot

# ─── Load config ──────────────────────────────────────────────────────────────
$cfgCvmPassword = $null

if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }
    $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    if (-not $ClusterName) { $ClusterName = $config.clusterName }
    # Prefer a direct CVM IP from nodes[] over the cluster VIP — avoids 127.0.0.1 from hostname -i
    if (-not $CvmIP) {
        $firstNode = @($config.network.nodes | Where-Object { $_.cvm_ip }) | Select-Object -First 1
        if ($firstNode -and $firstNode.cvm_ip) {
            $CvmIP = $firstNode.cvm_ip
        } elseif ($config.network.cluster_vip) {
            $CvmIP = $config.network.cluster_vip
        }
    }
    if ($config.PSObject.Properties['health_check'] -and $config.health_check.PSObject.Properties['cvm_password']) {
        $cfgCvmPassword = $config.health_check.cvm_password
    }
}

if (-not $CvmIP) {
    Write-Host "ERROR: CVM IP not found — provide -ConfigFile (with network.cluster_vip) or -CvmIP." -ForegroundColor Red
    exit 1
}

# ─── Resolve CVM password ─────────────────────────────────────────────────────
# Order: parameter → CSV → config → factory default
function Find-CvmPasswordFromCsv {
    param([string]$Name, [string]$Dir)
    if (-not $Name -or -not $Dir) { return $null }
    $csvPath = Join-Path $Dir "${Name}_Password.csv"
    if (-not (Test-Path $csvPath)) { return $null }
    try {
        foreach ($line in (Get-Content $csvPath -ErrorAction Stop)) {
            # Skip header and comment lines
            if ($line -match '^\s*#' -or $line -match '^Name\s') { continue }
            # Columns: Name(0)  Server(1)  Username(2)  Password(3)  Tags(4)  Folder(5)  Notes(6)
            $parts = $line.Trim() -split '\s+'
            if ($parts.Count -ge 4 -and $parts[0] -eq "${Name}_CVM_Nutanix") {
                return $parts[3]
            }
        }
    } catch { }
    return $null
}

$pwdSource  = ''
$pwdCsvPath = ''
if ($PSBoundParameters.ContainsKey('CvmPassword') -and $CvmPassword) {
    $pwdSource = '-CvmPassword parameter'
} else {
    if ($ClusterName) {
        $pwdCsvPath = Join-Path $scriptDir "${ClusterName}_Password.csv"
    }
    $csvPwd = Find-CvmPasswordFromCsv -Name $ClusterName -Dir $scriptDir
    if ($csvPwd) {
        $CvmPassword = $csvPwd
        $pwdSource   = "password CSV  (${ClusterName}_Password.csv)"
    } elseif ($cfgCvmPassword) {
        $CvmPassword = $cfgCvmPassword
        $pwdSource   = 'config  (health_check.cvm_password)'
    } else {
        $CvmPassword = 'nutanix/4u'
        $pwdSource   = 'factory default  (nutanix/4u)'
    }
}

# ─── Ensure Posh-SSH ──────────────────────────────────────────────────────────
Import-Module Posh-SSH -ErrorAction SilentlyContinue
if (-not (Get-Command New-SSHSession -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Posh-SSH is not installed." -ForegroundColor Red
    Write-Host "  Install with:  Install-Module Posh-SSH -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}

# Shared credential object
$secPass    = ConvertTo-SecureString $CvmPassword -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($CvmUsername, $secPass)

# ─── SSH helper: open session ─────────────────────────────────────────────────
# Posh-SSH 3.x emits a TrustedHost object to the pipeline alongside the SshSession
# when -AcceptKey adds a new host key (i.e. a host not yet in known_hosts).
# If we capture that mix into $s1, Invoke-SSHCommand -SSHSession $s1 fails with
# "Cannot index into a null array."  We therefore collect all output and filter
# for the object that carries a SessionId property (the SshSession).
function Open-CvmSession {
    param([string]$IP)
    $raw = $null
    try {
        $raw = New-SSHSession -ComputerName $IP -Credential $credential -AcceptKey -Port 22 -ErrorAction Stop
    } catch {
        try {
            $raw = New-SSHSession -ComputerName $IP -Credential $credential -AcceptKey -Force -Port 22 -ErrorAction Stop
        } catch {
            throw "SSH to $IP failed: $($_.Exception.Message)"
        }
    }
    # Extract the SshSession from the (possibly mixed) output array
    $s = @($raw) | Where-Object { $_ -ne $null -and $_.PSObject.Properties.Name -contains 'SessionId' } | Select-Object -Last 1
    if (-not $s) { throw "SSH to $IP : session was not created (raw output: $raw)" }
    return $s
}

# ─── Banner ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "    NCC System Health Check  —  SSH to CVM                     " -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  CVM IP/VIP      : $CvmIP"           -ForegroundColor Gray
Write-Host "  SSH User        : $CvmUsername"      -ForegroundColor Gray
Write-Host "  Password source : $pwdSource"        -ForegroundColor Gray
if ($pwdCsvPath) {
    $csvFound = Test-Path $pwdCsvPath
    $csvStatus = if ($csvFound) { 'found  ✓' } else { 'not found  (Step 15 may not have run yet)' }
    $csvColor  = if ($csvFound) { 'Green' } else { 'DarkGray' }
    Write-Host "  CSV looked up   : $pwdCsvPath" -ForegroundColor $csvColor
    Write-Host "                    $csvStatus" -ForegroundColor $csvColor
}
if ($ClusterName) {
    Write-Host "  Cluster         : $ClusterName"  -ForegroundColor Gray
}
Write-Host "  Timeout         : $TaskTimeoutMinutes min  (poll every $TaskPollSeconds s)" -ForegroundColor Gray
Write-Host ""

# ─── Step 1: Connect, check for running NCC, submit new NCC run ───────────────
Write-Host "Step 1: Connecting to CVM and starting NCC health checks..." -ForegroundColor Yellow

$nccAlreadyRunning = $false
$s1                = $null

try {
    $s1 = Open-CvmSession -IP $CvmIP

    # Check for already-running NCC tasks
    $preR = Invoke-SSHCommand -SSHSession $s1 `
        -Command 'bash -l -c "ecli task.list include_completed=false 2>/dev/null"' `
        -TimeOut 20 -ErrorAction SilentlyContinue
    if ($preR -and $preR.Output -match '\bNCC\b' -and $preR.Output -match 'kRunning|kQueued') {
        Write-Host "  [INFO] NCC is already running — waiting for it to complete..." -ForegroundColor Yellow
        $nccAlreadyRunning = $true
    } else {
        # Launch NCC in the background using nohup so it survives the SSH session close
        Write-Host "  Launching: ncc health_checks run_all" -ForegroundColor Gray
        $nccLaunch = Invoke-SSHCommand -SSHSession $s1 `
            -Command 'bash -l -c "nohup ncc health_checks run_all > /tmp/ncc-ztd.log 2>&1 & echo NCC_PID=\$!"' `
            -TimeOut 20
        # Join output array to a string before -match so that $Matches is set correctly.
        # Using -match on an array does filtering only and never populates $Matches.
        $nccPidLine = ($nccLaunch.Output -join '')
        if ($nccPidLine -match 'NCC_PID=(\d+)') {
            Write-Host "  ✓ NCC health check started  (PID $($Matches[1]))" -ForegroundColor Green
        } else {
            Write-Host "  ✓ NCC health check start command sent." -ForegroundColor Green
        }
        Write-Host "  Waiting 25 s for NCC tasks to register in ecli..." -ForegroundColor Gray
    }
} catch {
    Write-Host "  ✗ Cannot connect to ${CvmIP}: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($s1) { Remove-SSHSession -SSHSession $s1 -ErrorAction SilentlyContinue | Out-Null; $s1 = $null }
}

if (-not $nccAlreadyRunning) { Start-Sleep -Seconds 25 }

# ─── Step 2: Poll ecli task.list until all NCC tasks complete ─────────────────
Write-Host "`nStep 2: Monitoring NCC via ecli task.list..." -ForegroundColor Yellow
Write-Host "  Max wait: $TaskTimeoutMinutes minutes  (poll every $TaskPollSeconds s)" -ForegroundColor Gray
Write-Host ""

$deadline = (Get-Date).AddMinutes($TaskTimeoutMinutes)
$start    = Get-Date
$seenNcc  = $false
$nccDone  = $false
$lastMsg  = ''

while ((Get-Date) -lt $deadline) {
    $elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds)
    $s2      = $null

    try {
        $s2  = Open-CvmSession -IP $CvmIP
        $ecR = Invoke-SSHCommand -SSHSession $s2 `
            -Command 'bash -l -c "ecli task.list include_completed=false 2>/dev/null"' `
            -TimeOut 25
        Remove-SSHSession -SSHSession $s2 -ErrorAction SilentlyContinue | Out-Null
        $s2 = $null

        # Filter for NCC tasks that are actively running/queued
        $nccLines = @(
            ($ecR.Output -split "`n") |
            Where-Object { $_ -match '\bNCC\b' -and $_ -match 'kRunning|kQueued' }
        )

        if ($nccLines.Count -gt 0) {
            $seenNcc    = $true
            $slaveCnt   = @($nccLines | Where-Object { $_ -match 'HealthCheckSlave' }).Count
            $parentLine = $nccLines | Where-Object { $_ -match '\bHealthCheck\b' -and $_ -notmatch 'HealthCheckSlave' } | Select-Object -First 1
            $parentUuid = if ($parentLine -match '([0-9a-f-]{36})') { "[$($Matches[1].Substring(0,8))…]" } else { '' }

            $msg = "  [{0,4}s]  Running — {1} slave check(s) in progress  {2}" -f $elapsed, $slaveCnt, $parentUuid
            if ($msg -ne $lastMsg) {
                Write-Host $msg -ForegroundColor Cyan
                $lastMsg = $msg
            }
        } else {
            if ($seenNcc) {
                # Tasks appeared earlier but are gone now — NCC finished
                Write-Host ("  [{0,4}s]  ✓ All NCC tasks completed." -f $elapsed) -ForegroundColor Green
                $nccDone = $true
                break
            } elseif ($elapsed -gt 90) {
                # Never saw NCC tasks after 90 s — treat as already finished or fast completion
                Write-Host ("  [{0,4}s]  No NCC tasks detected in ecli — assuming NCC completed or log is fresh." -f $elapsed) -ForegroundColor Yellow
                $nccDone = $true
                break
            } else {
                $msg = "  [{0,4}s]  Waiting for NCC tasks to appear in ecli..." -f $elapsed
                if ($msg -ne $lastMsg) {
                    Write-Host $msg -ForegroundColor Gray
                    $lastMsg = $msg
                }
            }
        }
    } catch {
        Write-Host ("  [{0,4}s]  Poll error: {1}" -f $elapsed, $_.Exception.Message) -ForegroundColor Yellow
    } finally {
        if ($s2) { Remove-SSHSession -SSHSession $s2 -ErrorAction SilentlyContinue | Out-Null }
    }

    Start-Sleep -Seconds $TaskPollSeconds
}

if (-not $nccDone) {
    Write-Host ""
    Write-Host "  ✗ NCC did not complete within $TaskTimeoutMinutes minutes." -ForegroundColor Red
    exit 1
}

# ─── Step 3: Retrieve NCC output log from CVM ────────────────────────────────
Write-Host "`nStep 3: Retrieving NCC log from $CvmIP..." -ForegroundColor Yellow

$nccLogPath = '/home/nutanix/data/logs/ncc-output-latest.log'
$rawLog     = $null
$s3         = $null

try {
    $s3   = Open-CvmSession -IP $CvmIP
    $catR = Invoke-SSHCommand -SSHSession $s3 -Command "cat $nccLogPath" -TimeOut 90
    Remove-SSHSession -SSHSession $s3 -ErrorAction SilentlyContinue | Out-Null
    $s3 = $null

    if ($catR.ExitStatus -eq 0 -and $catR.Output) {
        $rawLog = $catR.Output -split "`n"
        Write-Host "  ✓ Log retrieved — $($rawLog.Count) lines." -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Log is empty or not found at: $nccLogPath" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [WARN] Could not retrieve log: $($_.Exception.Message)" -ForegroundColor Yellow
} finally {
    if ($s3) { Remove-SSHSession -SSHSession $s3 -ErrorAction SilentlyContinue | Out-Null }
}

if (-not $rawLog) {
    Write-Host ""
    Write-Host "  To review results manually, SSH to $CvmIP and run:" -ForegroundColor Cyan
    Write-Host "    cat $nccLogPath" -ForegroundColor Gray
    exit 0
}

# ─── Step 4: Parse and display NCC results ───────────────────────────────────
Write-Host "`nStep 4: Parsing NCC results..." -ForegroundColor Yellow
Write-Host ""

# Parse check-result lines:  /health_checks/<category>/<check_name>    [ STATUS ]
$checkList = [System.Collections.Generic.List[hashtable]]::new()
foreach ($line in $rawLog) {
    if ($line -match '^\s*(/health_checks/\S+)\s+\[\s*(\w+)\s*\]') {
        $checkList.Add(@{
            Path   = $Matches[1].Trim()
            Name   = ($Matches[1].Trim() -split '/')[-1]
            Status = $Matches[2].Trim().ToUpper()
        })
    }
}

# Parse "Detailed information for <check_name>:" blocks
$detailBlocks = @{}
$curBlock     = $null
$blockBuf     = [System.Collections.Generic.List[string]]::new()
foreach ($line in $rawLog) {
    if ($line -match '^Detailed information for (\S+?):') {
        if ($curBlock) { $detailBlocks[$curBlock] = $blockBuf.ToArray() }
        $curBlock = $Matches[1]
        $blockBuf = [System.Collections.Generic.List[string]]::new()
    } elseif ($curBlock) {
        if ($line -match '^\+[-=+]+\+') {
            $detailBlocks[$curBlock] = $blockBuf.ToArray()
            $curBlock = $null
        } else {
            $blockBuf.Add($line)
        }
    }
}
if ($curBlock -and $blockBuf.Count -gt 0) { $detailBlocks[$curBlock] = $blockBuf.ToArray() }

# Summary counts
$passCt  = @($checkList | Where-Object { $_.Status -eq 'PASS'                 }).Count
$infoCt  = @($checkList | Where-Object { $_.Status -eq 'INFO'                 }).Count
$warnCt  = @($checkList | Where-Object { $_.Status -in @('WARN','WARNING')     }).Count
$failCt  = @($checkList | Where-Object { $_.Status -eq 'FAIL'                 }).Count
$errCt   = @($checkList | Where-Object { $_.Status -eq 'ERR'                  }).Count
$totalCt = $checkList.Count

$bannerColor = if ($failCt -gt 0 -or $errCt -gt 0) { 'Red' } elseif ($warnCt -gt 0) { 'Yellow' } else { 'Green' }

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor $bannerColor
Write-Host "  NCC Health Check Results" -ForegroundColor $bannerColor
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor $bannerColor
Write-Host ""

if ($totalCt -eq 0) {
    Write-Host "  [WARN] No check results parsed from log — the log may still be empty or NCC is still running." -ForegroundColor Yellow
    Write-Host "  Log path on CVM: $nccLogPath" -ForegroundColor Gray
    exit 0
}

Write-Host ("  Total checks   : {0}" -f $totalCt) -ForegroundColor White
Write-Host ("  Passed         : {0}" -f $passCt)  -ForegroundColor Green
if ($infoCt -gt 0) { Write-Host ("  Info           : {0}" -f $infoCt)  -ForegroundColor Cyan   }
if ($warnCt -gt 0) { Write-Host ("  Warnings       : {0}" -f $warnCt) -ForegroundColor Yellow }
if ($failCt -gt 0) { Write-Host ("  Failed         : {0}" -f $failCt) -ForegroundColor Red    }
if ($errCt  -gt 0) { Write-Host ("  Errors         : {0}" -f $errCt)  -ForegroundColor Red    }

# Display non-passing checks sorted by severity
$nonPassing = @($checkList | Where-Object { $_.Status -ne 'PASS' })

if ($nonPassing.Count -gt 0) {
    Write-Host ""
    Write-Host "  Non-passing checks:" -ForegroundColor Yellow
    Write-Host ""

    $sevOrder = @{ FAIL = 0; ERR = 1; WARN = 2; WARNING = 3; INFO = 4 }
    $sorted   = $nonPassing | Sort-Object {
        $s = $_.Status
        if ($sevOrder.ContainsKey($s)) { $sevOrder[$s] } else { 99 }
    }

    foreach ($c in $sorted) {
        $color = switch ($c.Status) {
            'FAIL'    { 'Red'    }
            'ERR'     { 'Red'    }
            'WARN'    { 'Yellow' }
            'WARNING' { 'Yellow' }
            'INFO'    { 'Cyan'   }
            default   { 'Gray'   }
        }
        Write-Host ("  [{0}]  {1}" -f $c.Status.PadRight(5), $c.Path) -ForegroundColor $color

        if ($detailBlocks.ContainsKey($c.Name)) {
            foreach ($dline in $detailBlocks[$c.Name]) {
                $dtrim = $dline.Trim()
                if (-not $dtrim) { continue }
                if ($dtrim -match '^Refer to KB (\d+) \(([^)]+)\)') {
                    Write-Host ("    KB Article  : KB{0}  {1}" -f $Matches[1], $Matches[2]) -ForegroundColor Cyan
                } elseif ($dtrim -match '^or Recheck with:') {
                    # Skip verbose recheck command lines
                } elseif ($dtrim -match '^Node (\S+):') {
                    Write-Host ("    Node {0}" -f $Matches[1]) -ForegroundColor DarkGray
                } else {
                    $lineColor = 'Gray'
                    if ($dtrim -match '^(FAIL|ERR)\s*:') { $lineColor = 'Red'    }
                    elseif ($dtrim -match '^WARN\s*:')    { $lineColor = 'Yellow' }
                    Write-Host "      $dtrim" -ForegroundColor $lineColor
                }
            }
        }
        Write-Host ""
    }
} else {
    Write-Host ""
    Write-Host "  ✓ All checks passed!" -ForegroundColor Green
}

# ─── Emit structured NCC markers for pipeline email ──────────────────────────
# Start-Pipeline.ps1 parses these lines from the unified run log to build an
# HTML summary section that is injected into the result email.
Write-Host "[NCC-REPORT-START]"
Write-Host "[NCC-SUMMARY] TOTAL=$totalCt PASS=$passCt INFO=$infoCt WARN=$warnCt FAIL=$failCt ERR=$errCt"
foreach ($c in ($checkList | Where-Object { $_.Status -ne 'PASS' })) {
    # First meaningful detail line (skip node headers, KB refs, recheck commands)
    $firstDetail = ''
    if ($detailBlocks.ContainsKey($c.Name)) {
        $firstDetail = @($detailBlocks[$c.Name] |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '^Node \S+:' -and $_ -notmatch '^Refer to KB' -and $_ -notmatch '^or Recheck' } |
            Select-Object -First 1) -join ''
    }
    $kbNum = ''
    if ($detailBlocks.ContainsKey($c.Name)) {
        $kbLine = $detailBlocks[$c.Name] | Where-Object { $_ -match 'KB (\d+)' } | Select-Object -First 1
        if ($kbLine -match 'KB (\d+)') { $kbNum = $Matches[1] }
    }
    # Use | as field separator; sanitise fields to prevent accidental splits
    $safeDetail = ($firstDetail -replace '\|', '/').Substring(0, [math]::Min($firstDetail.Length, 160))
    Write-Host "[NCC-CHECK] $($c.Status)|$($c.Path)|$safeDetail|$kbNum"
}
Write-Host "[NCC-REPORT-END]"

Write-Host ""
# Exit 0 — the health check completed and results are in the report.
# Non-zero exits are reserved for infrastructure failures (SSH unreachable,
# ecli timeout, log retrieval failure) where NCC could not run at all.
# FAIL/WARN findings are surfaced in the console output and pipeline email.
if ($failCt -gt 0) {
    Write-Host "  ⚠  $failCt check(s) FAILED — see details above and the pipeline email report." -ForegroundColor Yellow
} elseif ($warnCt -gt 0) {
    Write-Host "  ⚠  $warnCt check(s) returned WARN — see details above." -ForegroundColor Yellow
}
exit 0
