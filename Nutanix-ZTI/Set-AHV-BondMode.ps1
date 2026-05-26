<#
.SYNOPSIS
    Checks and changes OVS bond mode on all AHV nodes in a Nutanix cluster.

.DESCRIPTION
    Queries Prism Element to discover all AHV host IPs, then SSHs to each host to
    check the OVS bond mode. If bond is balance-tcp with LACP negotiated, it reverts
    to active-backup with LACP off. Waits 60 seconds between nodes.

.PARAMETER ConfigFile
    Path to the JSON deployment config file. The cluster VIP is read from network.cluster_vip.

.PARAMETER ClusterVIP
    Prism Element cluster VIP or IP. Overrides the value from ConfigFile if both are provided.

.PARAMETER BondName
    OVS bond name to manage (default: br0-up).

.PARAMETER WaitSeconds
    Seconds to wait between nodes (default: 60).

.PARAMETER ForceChange
    If specified, applies the change regardless of current bond state.

    Credentials are hardcoded to Nutanix factory defaults:
      Prism Element admin: Nutanix/4u
      AHV root:            nutanix/4u

.EXAMPLE
    .\Set-AHV-BondMode.ps1 -ConfigFile .\Configs\my-cluster.json

.EXAMPLE
    .\Set-AHV-BondMode.ps1 -ConfigFile .\Configs\my-cluster.json -ForceChange -WaitSeconds 30

.NOTES
    Author: Sonu Agarwal
    Date: Apr 12, 2026
    Version: 1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)] [string]$ConfigFile,
    [Parameter(Mandatory=$false)] [string]$ClusterVIP,
    [Parameter(Mandatory=$false)] [string]$BondName    = "br0-up",
    [Parameter(Mandatory=$false)] [int]   $WaitSeconds = 60,
    [Parameter(Mandatory=$false)] [switch]$ForceChange
)

# ── Hardcoded default Nutanix credentials ────────────────────────────────────
$ClusterUsername = "admin"
$ClusterPassword = "Nutanix/4u"
$AHVUsername     = "root"
$AHVPassword     = "nutanix/4u"

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

if (-not $ClusterVIP) {
    Write-Host "ERROR: ClusterVIP must be provided via -ConfigFile or -ClusterVIP." -ForegroundColor Red
    exit 1
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
        try {
            $session = New-SSHSession -ComputerName $HostIP -Credential $Cred `
                -AcceptKey -ErrorAction Stop
            return $session
        } catch {
            throw "SSH connection to $HostIP failed: $_"
        }
    }
}

# ── Helper: run SSH command and return stdout ────────────────────────────────
function Invoke-AHVCommand {
    param($Session, [string]$Command)
    $result = Invoke-SSHCommand -SessionId $Session.SessionId -Command $Command -TimeOut 30
    return $result.Output -join "`n"
}

# ── Step 1: Get AHV hosts from Prism Element API ─────────────────────────────
Write-Host "`n=== AHV Bond Mode Manager ===" -ForegroundColor Cyan
Write-Host "Cluster VIP : $ClusterVIP"
Write-Host "Bond Name   : $BondName"
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
    exit 1
}

$ahvHosts = $hostsResponse.entities | Where-Object { $_.hypervisor_type -eq "kKvm" -or $_.hypervisor_address -ne $null } |
    Select-Object name, hypervisor_address, serial

if (-not $ahvHosts -or $ahvHosts.Count -eq 0) {
    Write-Host "ERROR: No AHV hosts found in cluster response." -ForegroundColor Red
    exit 1
}

Write-Host "Found $($ahvHosts.Count) AHV host(s):" -ForegroundColor Green
$ahvHosts | ForEach-Object { Write-Host "  - $($_.name)  [$($_.hypervisor_address)]" }

# ── Step 2: Process each host ────────────────────────────────────────────────
$ahvCred = New-Object System.Management.Automation.PSCredential(
    $AHVUsername,
    (ConvertTo-SecureString $AHVPassword -AsPlainText -Force)
)

$totalHosts = $ahvHosts.Count
$index = 0

foreach ($ahvNode in $ahvHosts) {
    $index++
    $ahvIP = $ahvNode.hypervisor_address
    $ahvName = $ahvNode.name

    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
    Write-Host "[$index/$totalHosts] Host: $ahvName  IP: $ahvIP" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan

    # Connect via SSH
    Write-Host "Connecting via SSH..." -ForegroundColor Yellow
    try {
        $sshSession = New-AHVSSHSession -HostIP $ahvIP -Cred $ahvCred
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

        # Parse current state
        $currentMode  = if ($bondOutput -match "bond_mode:\s+(\S+)") { $Matches[1] } else { "unknown" }
        $currentLacp  = if ($bondOutput -match "lacp_status:\s+(\S+)") { $Matches[1] } else { "unknown" }

        Write-Host ""
        Write-Host "  Current bond_mode  : $currentMode" -ForegroundColor White
        Write-Host "  Current lacp_status: $currentLacp" -ForegroundColor White

        # ── Decide whether to change ─────────────────────────────────────
        $alreadyCorrect = ($currentMode -eq "balance-tcp" -and $currentLacp -eq "negotiated")
        $needsChange    = $ForceChange -or (-not $alreadyCorrect)

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
            Write-Host "`n[VERIFY] Checking bond status after change..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
            $verifyOutput = Invoke-AHVCommand -Session $sshSession -Command "ovs-appctl bond/show $BondName"
            Write-Host $verifyOutput -ForegroundColor Gray

            $newMode = if ($verifyOutput -match "bond_mode:\s+(\S+)") { $Matches[1] } else { "unknown" }
            $newLacp = if ($verifyOutput -match "lacp_status:\s+(\S+)") { $Matches[1] } else { "unknown" }

            Write-Host ""
            if ($newMode -eq "balance-tcp" -and $newLacp -eq "negotiated") {
                Write-Host "  [OK] bond_mode  : $newMode" -ForegroundColor Green
                Write-Host "  [OK] lacp_status: $newLacp" -ForegroundColor Green
                Write-Host "`nChange applied successfully on $ahvName." -ForegroundColor Green
            } else {
                Write-Host "  [WARN] bond_mode  : $newMode  (expected: balance-tcp)" -ForegroundColor Yellow
                Write-Host "  [WARN] lacp_status: $newLacp  (expected: negotiated)" -ForegroundColor Yellow
                Write-Host "`nWARNING: LACP may still be negotiating — verify manually with: ovs-appctl bond/show" -ForegroundColor Yellow
            }
        }
    } finally {
        Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
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