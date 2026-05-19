<#
.SYNOPSIS
    Checks and changes OVS bond mode on all AHV nodes — accepts custom credentials and/or explicit AHV host IPs.

.DESCRIPTION
    Same as Set-AHV-BondMode.ps1 but credentials are provided as parameters instead of being hardcoded.
    Optionally accepts a comma-separated list of AHV host IPs to bypass Prism Element API discovery entirely.

    Two ways to provide AHV hosts:
      A) Provide -ClusterVIP + Prism credentials → auto-discovers AHV hosts via Prism Element API.
      B) Provide -AHVHosts directly → skips Prism API entirely, only SSH credentials are needed.

.PARAMETER ConfigFile
    Path to the JSON deployment config file. The cluster VIP is read from network.cluster_vip.

.PARAMETER ClusterVIP
    Prism Element cluster VIP or IP. Overrides the value from ConfigFile if both are provided.
    Not needed if -AHVHosts is specified directly.

.PARAMETER ClusterUsername
    Prism Element admin username. Default: admin.

.PARAMETER ClusterPassword
    Prism Element admin password. If not provided, you will be prompted securely.

.PARAMETER AHVHosts
    Comma-separated list of AHV hypervisor IPs (or IP:password pairs if each node has a different password).
    Example (same password): "10.0.1.1,10.0.1.2,10.0.1.3"
    Example (per-host passwords): "10.0.1.1:Pass1,10.0.1.2:Pass2,10.0.1.3:Pass3"

.PARAMETER AHVHostsFile
    Path to a CSV file with per-host credentials. Columns: IP, Password (and optionally Username).
    Example CSV:
        IP,Username,Password
        10.0.1.1,root,Pass1
        10.0.1.2,root,Pass2
        10.0.1.3,root,Pass3

.PARAMETER AHVUsername
    AHV SSH username. Default: root. Used when a per-host entry has no Username column.

.PARAMETER AHVPassword
    AHV SSH password shared across all nodes. Default: nutanix/4u (Nutanix factory default).
    Override if the password has been changed. Per-host passwords via -AHVHostsFile take priority.

.PARAMETER BondName
    OVS bond name to manage. Default: br0-up.

.PARAMETER WaitSeconds
    Seconds to wait between nodes. Default: 60.

.PARAMETER ForceChange
    If specified, applies the change regardless of current bond state.

.EXAMPLE
    # Auto-discover hosts via Prism, AHV password is still factory default:
    .\Set-AHV-BondMode-Custom.ps1 -ClusterVIP 10.0.1.100 -ClusterPassword 'MyAdminPass'

.EXAMPLE
    # Auto-discover hosts via Prism with custom passwords for both:
    .\Set-AHV-BondMode-Custom.ps1 -ClusterVIP 10.0.1.100 -ClusterPassword 'MyAdminPass' -AHVPassword 'MyRootPass'

.EXAMPLE
    # Provide AHV hosts directly with a shared password (no Prism API needed):
    .\Set-AHV-BondMode-Custom.ps1 -AHVHosts "10.0.1.1,10.0.1.2,10.0.1.3" -AHVPassword "MyRootPass"

.EXAMPLE
    # Each node has a different password — inline IP:password format:
    .\Set-AHV-BondMode-Custom.ps1 -AHVHosts "10.0.1.1:Pass1,10.0.1.2:Pass2,10.0.1.3:Pass3"

.EXAMPLE
    # Each node has a different password — CSV file:
    .\Set-AHV-BondMode-Custom.ps1 -AHVHostsFile .\ahv-hosts.csv

.EXAMPLE
    # Prompt for passwords interactively:
    .\Set-AHV-BondMode-Custom.ps1 -ClusterVIP 10.0.1.100

.EXAMPLE
    # Using a config file with custom passwords:
    .\Set-AHV-BondMode-Custom.ps1 -ConfigFile .\Configs\DKCDC-1P-NTXTEST-03.json -ClusterPassword "MyAdminPass" -AHVPassword "MyRootPass" -ForceChange
#>

#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)] [string]$ConfigFile,
    [Parameter(Mandatory=$false)] [string]$ClusterVIP,
    [Parameter(Mandatory=$false)] [string]$ClusterUsername = "admin",
    [Parameter(Mandatory=$false)] [string]$ClusterPassword,
    [Parameter(Mandatory=$false)] [string]$AHVHosts,
    [Parameter(Mandatory=$false)] [string]$AHVHostsFile,
    [Parameter(Mandatory=$false)] [string]$AHVUsername     = "root",
    [Parameter(Mandatory=$false)] [string]$AHVPassword      = "nutanix/4u",
    [Parameter(Mandatory=$false)] [string]$BondName        = "br0-up",
    [Parameter(Mandatory=$false)] [int]   $WaitSeconds     = 60,
    [Parameter(Mandatory=$false)] [switch]$ForceChange
)

# ── Resolve ClusterVIP from config file if provided ──────────────────────────
if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if (-not $ClusterVIP) {
        $ClusterVIP = $cfg.network.cluster_vip
    }
}

# ── Validate inputs ──────────────────────────────────────────────────────────
$usingDirectHosts   = ($AHVHosts     -and $AHVHosts.Trim()     -ne "")
$usingHostsFile     = ($AHVHostsFile -and $AHVHostsFile.Trim() -ne "")
$usingPerHostCreds  = $false   # determined below

if (-not $usingDirectHosts -and -not $usingHostsFile -and -not $ClusterVIP) {
    Write-Host "ERROR: Provide -ClusterVIP, -AHVHosts, or -AHVHostsFile." -ForegroundColor Red
    exit 1
}

# ── Detect inline per-host passwords (IP:password format) ───────────────────
# If any entry in -AHVHosts contains a colon, treat all entries as IP:password
if ($usingDirectHosts -and ($AHVHosts -match ":[^,]+")) {
    $usingPerHostCreds = $true
}
if ($usingHostsFile) {
    $usingPerHostCreds = $true
}

# ── Prompt for passwords if needed ──────────────────────────────────────────
if (-not $usingDirectHosts -and -not $usingHostsFile -and -not $ClusterPassword) {
    $ClusterPassword = Read-Host "Enter Prism Element password for '$ClusterUsername'" -AsSecureString |
        ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }
}

# ── Posh-SSH check ───────────────────────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Write-Host "Posh-SSH module not found. Installing..." -ForegroundColor Yellow
    try {
        Install-Module -Name Posh-SSH -Force -Scope CurrentUser
        Write-Host "Posh-SSH installed successfully." -ForegroundColor Green
    } catch {
        Write-Host "ERROR: Failed to install Posh-SSH. $_" -ForegroundColor Red
        exit 1
    }
}
Import-Module Posh-SSH -ErrorAction Stop

# ── Helper: ignore untrusted SSH host keys ───────────────────────────────────
function New-AHVSSHSession {
    param([string]$HostIP, [System.Management.Automation.PSCredential]$Cred)
    try {
        $session = New-SSHSession -ComputerName $HostIP -Credential $Cred `
            -AcceptKey -Force -ErrorAction Stop
        return $session
    } catch {
        $session = New-SSHSession -ComputerName $HostIP -Credential $Cred `
            -AcceptKey -ErrorAction Stop
        return $session
    }
}

# ── Helper: run SSH command and return stdout ────────────────────────────────
function Invoke-AHVCommand {
    param($Session, [string]$Command)
    $result = Invoke-SSHCommand -SessionId $Session.SessionId -Command $Command -TimeOut 30
    return $result.Output -join "`n"
}

# ── Helper: RFC 4180 CSV parser (backtick is NOT special — only "" escapes ") ─
function Read-CsvRfc4180 {
    param([string]$FilePath)
    $lines = Get-Content $FilePath -Encoding UTF8
    if ($lines.Count -lt 2) { return @() }
    $headers = $lines[0] -split ','
    $results = @()
    $i = 1
    while ($i -lt $lines.Count) {
        $line = $lines[$i]; $i++
        $fields = @(); $pos = 0
        while ($pos -le $line.Length) {
            if ($pos -lt $line.Length -and $line[$pos] -eq '"') {
                # Quoted field
                $pos++; $field = ''
                while ($true) {
                    if ($pos -ge $line.Length) {
                        # Multi-line field — append next line
                        if ($i -lt $lines.Count) { $field += "`n"; $line += "`n" + $lines[$i]; $i++ }
                        else { break }
                    }
                    if ($line[$pos] -eq '"') {
                        if ($pos + 1 -lt $line.Length -and $line[$pos + 1] -eq '"') {
                            $field += '"'; $pos += 2  # "" → literal "
                        } else { $pos++; break }      # closing quote
                    } else { $field += $line[$pos]; $pos++ }
                }
                $fields += $field
                if ($pos -lt $line.Length -and $line[$pos] -eq ',') { $pos++ }
            } else {
                # Unquoted field
                $end = $line.IndexOf(',', $pos)
                if ($end -lt 0) { $fields += $line.Substring($pos); $pos = $line.Length + 1 }
                else            { $fields += $line.Substring($pos, $end - $pos); $pos = $end + 1 }
            }
        }
        $obj = [PSCustomObject]@{}
        for ($j = 0; $j -lt $headers.Count; $j++) {
            $val = if ($j -lt $fields.Count) { $fields[$j] } else { '' }
            $obj | Add-Member -NotePropertyName $headers[$j].Trim() -NotePropertyValue $val
        }
        $results += $obj
    }
    return $results
}

Write-Host "`n=== AHV Bond Mode Manager (Custom Credentials) ===" -ForegroundColor Cyan
Write-Host "Bond Name   : $BondName"

# ── Step 1: Build list of AHV hosts ──────────────────────────────────────────
# Each entry: PSCustomObject with hypervisor_address, ssh_username, ssh_password
# NOTE: variable named $nodeList to avoid collision with $AHVHosts parameter (PS is case-insensitive)
$nodeList = [System.Collections.Generic.List[object]]::new()

if ($usingHostsFile) {
    # Load from CSV file
    if (-not (Test-Path $AHVHostsFile)) {
        Write-Host "ERROR: AHVHostsFile not found: $AHVHostsFile" -ForegroundColor Red
        exit 1
    }
    $ext = [System.IO.Path]::GetExtension($AHVHostsFile).ToLower()
    Write-Host "Mode        : Host file (Prism API skipped) [$ext]" -ForegroundColor Yellow
    Write-Host ""
    if ($ext -eq '.json') {
        $rawEntries = [System.IO.File]::ReadAllText((Resolve-Path $AHVHostsFile).Path) | ConvertFrom-Json
    } else {
        $rawEntries = Read-CsvRfc4180 $AHVHostsFile
    }
    foreach ($entry in $rawEntries) {
        $ip   = [string]$entry.IP
        $user = if ($entry.Username -and ([string]$entry.Username).Trim() -ne '') { ([string]$entry.Username).Trim() } else { $AHVUsername }
        $pass = [string]$entry.Password
        $nodeList.Add([PSCustomObject]@{ name = $ip; hypervisor_address = $ip; ssh_username = $user; ssh_password = $pass })
    }
    Write-Host "Using $($nodeList.Count) host(s) from host file '$AHVHostsFile':" -ForegroundColor Green
    $nodeList | ForEach-Object { Write-Host "  - $($_.hypervisor_address)  (user: $($_.ssh_username))" }

} elseif ($usingDirectHosts) {
    Write-Host "Mode        : Direct host list (Prism API skipped)" -ForegroundColor Yellow
    Write-Host ""
    if ($usingPerHostCreds) {
        # IP:password format
        $AHVHosts -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | ForEach-Object {
            $parts = $_ -split ":" , 2
            $ip    = $parts[0].Trim()
            $pass  = if ($parts.Count -gt 1) { $parts[1] } else { $AHVPassword }
            $nodeList.Add([PSCustomObject]@{ name = $ip; hypervisor_address = $ip; ssh_username = $AHVUsername; ssh_password = $pass })
        }
        Write-Host "Using $($nodeList.Count) host(s) with per-host passwords:" -ForegroundColor Green
        $nodeList | ForEach-Object { Write-Host "  - $($_.hypervisor_address)" }
    } else {
        $AHVHosts -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | ForEach-Object {
            $nodeList.Add([PSCustomObject]@{ name = $_; hypervisor_address = $_; ssh_username = $AHVUsername; ssh_password = $AHVPassword })
        }
        Write-Host "Using $($nodeList.Count) host(s) from -AHVHosts parameter:" -ForegroundColor Green
        $nodeList | ForEach-Object { Write-Host "  - $($_.hypervisor_address)" }
    }
} else {
    # Discover via Prism Element API
    Write-Host "Cluster VIP : $ClusterVIP"
    Write-Host "Prism User  : $ClusterUsername"
    Write-Host ""

    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${ClusterUsername}:${ClusterPassword}"))
    $headers = @{
        "Authorization" = "Basic $base64Auth"
        "Content-Type"  = "application/json"
        "Accept"        = "application/json"
    }

    Write-Host "Querying Prism Element for AHV host list..." -ForegroundColor Cyan
    try {
        $hostsResponse = Invoke-RestMethod `
            -Uri "https://${ClusterVIP}:9440/PrismGateway/services/rest/v2.0/hosts" `
            -Headers $headers `
            -Method Get `
            -SkipCertificateCheck `
            -ErrorAction Stop
    } catch {
        Write-Host "ERROR: Failed to query Prism Element at $ClusterVIP. Check IP and credentials." -ForegroundColor Red
        Write-Host "Details: $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "TIP: If you don't have Prism credentials, use -AHVHosts to provide host IPs directly:" -ForegroundColor Yellow
        Write-Host "  .\Set-AHV-BondMode-Custom.ps1 -AHVHosts `"10.x.x.1,10.x.x.2,10.x.x.3`" -AHVPassword `"pass`"" -ForegroundColor Yellow
        exit 1
    }

    $discovered = $hostsResponse.entities |
        Where-Object { $_.hypervisor_type -eq "kKvm" -or $_.hypervisor_address -ne $null } |
        Select-Object name, hypervisor_address, serial

    if (-not $discovered -or $discovered.Count -eq 0) {
        Write-Host "ERROR: No AHV hosts found in cluster response." -ForegroundColor Red
        exit 1
    }

    $discovered | ForEach-Object {
        $nodeList.Add([PSCustomObject]@{ name = $_.name; hypervisor_address = $_.hypervisor_address; ssh_username = $AHVUsername; ssh_password = $AHVPassword })
    }

    Write-Host "Found $($nodeList.Count) AHV host(s):" -ForegroundColor Green
    $nodeList | ForEach-Object { Write-Host "  - $($_.name)  [$($_.hypervisor_address)]" }
}

# ── Step 2: Process each host ────────────────────────────────────────────────
$totalHosts = $nodeList.Count
$index = 0

foreach ($ahvNode in $nodeList) {
    $index++
    $ahvIP      = $ahvNode.hypervisor_address
    $nodeUser   = $ahvNode.ssh_username
    $nodePass   = $ahvNode.ssh_password
    $ahvName    = if ($ahvNode.name -ne $ahvIP) { "$($ahvNode.name)  IP: $ahvIP" } else { $ahvIP }
    $nodeCred   = New-Object System.Management.Automation.PSCredential(
        $nodeUser,
        (ConvertTo-SecureString $nodePass -AsPlainText -Force)
    )

    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
    Write-Host "[$index/$totalHosts] Host: $ahvName" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan

    Write-Host "Connecting via SSH as '$nodeUser'..." -ForegroundColor Yellow
    try {
        $sshSession = New-AHVSSHSession -HostIP $ahvIP -Cred $nodeCred
    } catch {
        Write-Host "ERROR: Cannot SSH to $ahvIP. Skipping. $_" -ForegroundColor Red
        continue
    }
    Write-Host "Connected." -ForegroundColor Green

    try {
        # ── Check current bond status ────────────────────────────────────
        Write-Host "`n[CHECK] Running: ovs-appctl bond/show $BondName" -ForegroundColor Yellow
        $bondOutput = Invoke-AHVCommand -Session $sshSession -Command "ovs-appctl bond/show $BondName"
        Write-Host $bondOutput -ForegroundColor Gray

        $currentMode = if ($bondOutput -match "bond_mode:\s+(\S+)") { $Matches[1] } else { "unknown" }
        $currentLacp = if ($bondOutput -match "lacp_status:\s+(\S+)") { $Matches[1] } else { "unknown" }

        Write-Host ""
        Write-Host "  Current bond_mode  : $currentMode" -ForegroundColor White
        Write-Host "  Current lacp_status: $currentLacp" -ForegroundColor White

        # ── Decide whether to change ─────────────────────────────────────
        $alreadyCorrect = ($currentMode -eq "balance-tcp" -and $currentLacp -eq "negotiated")

        if ($alreadyCorrect -and -not $ForceChange) {
            Write-Host "`n[SKIP] Bond is already balance-tcp with LACP negotiated. No change needed." -ForegroundColor Green
        } else {
            if ($ForceChange) {
                Write-Host "`n[ACTION] ForceChange specified — applying LACP balance-tcp regardless of current state." -ForegroundColor Magenta
            } else {
                Write-Host "`n[ACTION] Bond is '$currentMode' / LACP '$currentLacp' — changing to balance-tcp with LACP active." -ForegroundColor Yellow
            }

            $changeCmd = "ovs-vsctl set port $BondName bond_mode=balance-tcp -- set port $BondName lacp=active"
            Write-Host "Running: $changeCmd" -ForegroundColor Yellow
            $changeOutput = Invoke-AHVCommand -Session $sshSession -Command $changeCmd
            if ($changeOutput) { Write-Host $changeOutput -ForegroundColor Gray }

            # ── Verify after change ───────────────────────────────────────
            # The bond change can temporarily drop the SSH session while LACP negotiates
            # with the switch. Wait up to 30s and reconnect with a fresh session to verify.
            Write-Host "`n[VERIFY] Waiting 15s for LACP to negotiate before verifying..." -ForegroundColor Yellow
            Start-Sleep -Seconds 15

            # Close the existing session (may already be dead) before reconnecting
            try { Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null } catch {}

            $verifySession = $null
            $verifyOutput  = ""
            for ($attempt = 1; $attempt -le 4; $attempt++) {
                try {
                    Write-Host "  Reconnecting for verify (attempt $attempt/4)..." -ForegroundColor DarkGray
                    $verifySession = New-AHVSSHSession -HostIP $ahvIP -Cred $nodeCred
                    $verifyOutput  = Invoke-AHVCommand -Session $verifySession -Command "ovs-appctl bond/show $BondName"
                    try { Remove-SSHSession -SessionId $verifySession.SessionId | Out-Null } catch {}
                    break
                } catch {
                    Write-Host "  Attempt $attempt failed: $_" -ForegroundColor DarkGray
                    if ($attempt -lt 4) { Start-Sleep -Seconds 10 }
                }
            }

            if ($verifyOutput) { Write-Host $verifyOutput -ForegroundColor Gray }
            else { Write-Host "  [WARN] Could not reconnect to verify — bond change was sent, check manually." -ForegroundColor Yellow }

            $newMode = if ($verifyOutput -match "bond_mode:\s+(\S+)") { $Matches[1] } else { "unknown" }
            $newLacp = if ($verifyOutput -match "lacp_status:\s+(\S+)") { $Matches[1] } else { "unknown" }

            Write-Host ""
            if ($newMode -eq "balance-tcp" -and $newLacp -eq "negotiated") {
                Write-Host "  [OK] bond_mode  : $newMode" -ForegroundColor Green
                Write-Host "  [OK] lacp_status: $newLacp" -ForegroundColor Green
                Write-Host "`nChange applied successfully on $($ahvNode.name)." -ForegroundColor Green
            } else {
                Write-Host "  [WARN] bond_mode  : $newMode  (expected: balance-tcp)" -ForegroundColor Yellow
                Write-Host "  [WARN] lacp_status: $newLacp  (expected: negotiated)" -ForegroundColor Yellow
                Write-Host "`nWARNING: LACP may still be negotiating — verify manually with: ovs-appctl bond/show" -ForegroundColor Yellow
            }
        }
    } finally {
        try { Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null } catch {}
        Write-Host "SSH session closed." -ForegroundColor DarkGray
    }

    # ── Wait between nodes ────────────────────────────────────────────────
    if ($index -lt $totalHosts) {
        Write-Host "`nWaiting $WaitSeconds seconds before next host..." -ForegroundColor Cyan
        for ($i = $WaitSeconds; $i -gt 0; $i -= 10) {
            $remaining = [Math]::Min($i, 10)
            Start-Sleep -Seconds $remaining
            Write-Host "  $($i - $remaining)s remaining..." -ForegroundColor DarkGray
        }
    }
}

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
Write-Host "All hosts processed." -ForegroundColor Green
exit 0
