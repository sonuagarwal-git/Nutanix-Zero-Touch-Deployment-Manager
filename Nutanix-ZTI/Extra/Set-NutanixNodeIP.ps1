#Requires -Version 7.0
<#
.SYNOPSIS
    Sets static IP addresses on a Nutanix AHV host and CVM via SSH.

.DESCRIPTION
    Connects via SSH to the AHV host (root) and CVM (nutanix) using their
    current DHCP IPs, writes static network configuration, applies it via
    a background network restart, then reconnects to the new IPs to verify.

.PARAMETER AhvCurrentIP
    Current (DHCP) IP of the AHV hypervisor host.

.PARAMETER CvmCurrentIP
    Current (DHCP) IP of the CVM.

.PARAMETER AhvNewIP
    Desired static IP for the AHV host.

.PARAMETER CvmNewIP
    Desired static IP for the CVM.

.PARAMETER Prefix
    Subnet prefix length (e.g. 26 for /26 = 255.255.255.192).

.PARAMETER Gateway
    Default gateway for both AHV and CVM.

.PARAMETER AhvUsername
    SSH username for AHV host (default: root).

.PARAMETER AhvPassword
    SSH password for AHV host (default: nutanix/4u).

.PARAMETER CvmUsername
    SSH username for CVM (default: nutanix).

.PARAMETER CvmPassword
    SSH password for CVM (default: nutanix/4u).

.PARAMETER ReconnectWaitSeconds
    Seconds to wait after triggering network restart before reconnecting.

.PARAMETER ReconnectAttempts
    Number of reconnect attempts before giving up.

.PARAMETER ProxyServer
    IP or hostname of a jump/bastion host that CAN reach the AHV/CVM IPs.
    Leave blank for direct SSH.

.PARAMETER ProxyPort
    SSH port on the proxy server (default: 22).

.PARAMETER ProxyUsername
    Username on the proxy server.

.PARAMETER ProxyPassword
    Password on the proxy server.

.EXAMPLE
    # Direct SSH (if reachable)
    .\Set-NutanixNodeIP.ps1 `
        -AhvCurrentIP 10.254.4.131 -CvmCurrentIP 10.254.4.132 `
        -AhvNewIP 10.254.4.156   -CvmNewIP 10.254.4.157 `
        -Prefix 26 -Gateway 10.254.4.129

.EXAMPLE
    # Via jump host
    .\Set-NutanixNodeIP.ps1 `
        -AhvCurrentIP 10.254.4.131 -CvmCurrentIP 10.254.4.132 `
        -AhvNewIP 10.254.4.156   -CvmNewIP 10.254.4.157 `
        -Prefix 26 -Gateway 10.254.4.129 `
        -ProxyServer 10.0.10.80 -ProxyUsername myuser -ProxyPassword mypass
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$AhvCurrentIP,
    [Parameter(Mandatory)] [string]$CvmCurrentIP,
    [Parameter(Mandatory)] [string]$AhvNewIP,
    [Parameter(Mandatory)] [string]$CvmNewIP,
    [Parameter(Mandatory)] [int]   $Prefix,
    [Parameter(Mandatory)] [string]$Gateway,

    [string]$AhvUsername          = 'root',
    [string]$AhvPassword          = 'nutanix/4u',
    [string]$CvmUsername          = 'nutanix',
    [string]$CvmPassword          = 'nutanix/4u',
    [int]   $ReconnectWaitSeconds = 15,
    [int]   $ReconnectAttempts    = 8,

    # Optional jump/proxy host
    [string]$ProxyServer   = '',
    [int]   $ProxyPort     = 22,
    [string]$ProxyUsername = '',
    [string]$ProxyPassword = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    throw "Posh-SSH not found. Install with: Install-Module Posh-SSH -Force"
}
Import-Module Posh-SSH -ErrorAction Stop

#region ── Helpers ──────────────────────────────────────────────────────────

function Write-Header  { param([string]$t) Write-Host ""; Write-Host ('=' * 70) -ForegroundColor Cyan; Write-Host "  $t" -ForegroundColor Cyan; Write-Host ('=' * 70) -ForegroundColor Cyan }
function Write-Step    { param([string]$t) Write-Host "`n  >> $t" -ForegroundColor Cyan }
function Write-Ok      { param([string]$t) Write-Host "     OK  : $t" -ForegroundColor Green }
function Write-Warn    { param([string]$t) Write-Host "     WARN: $t" -ForegroundColor Yellow }
function Write-Err     { param([string]$t) Write-Host "     ERR : $t" -ForegroundColor Red }

function New-SshCred {
    param([string]$User, [string]$Pass)
    [pscredential]::new($User, (ConvertTo-SecureString $Pass -AsPlainText -Force))
}

function New-SshSessionEx {
    # Wrapper around New-SSHSession that transparently adds proxy params when set.
    param([string]$IP, [string]$User, [string]$Pass)
    $cred = New-SshCred $User $Pass
    $extra = @{}
    if ($ProxyServer) {
        $extra['ProxyServer']     = $ProxyServer
        $extra['ProxyPort']       = $ProxyPort
        $extra['ProxyCredential'] = (New-SshCred $ProxyUsername $ProxyPassword)
        Write-Host "     (via proxy $ProxyServer)" -ForegroundColor DarkGray
    }
    New-SSHSession -ComputerName $IP -Credential $cred -AcceptKey -Force -ErrorAction Stop @extra
}

function Invoke-Ssh {
    param([int]$SessionId, [string]$Cmd, [int]$TimeoutSec = 30)
    $r = Invoke-SSHCommand -SessionId $SessionId -Command $Cmd -TimeOut $TimeoutSec
    return ($r.Output -join "`n")
}

function Write-Lines {
    # Writes an array of strings to a remote file using echo > / echo >>
    # Returns the bash command string (safe for Invoke-SSHCommand).
    param([string[]]$Lines, [string]$Path, [string]$Sudo = '')
    $parts = @()
    $parts += "${Sudo}bash -c `"echo '$(($Lines[0] -replace "'","'\\''"))' > $Path`""
    for ($i = 1; $i -lt $Lines.Count; $i++) {
        $escaped = $Lines[$i] -replace "'", "'\\'''"
        $parts += "${Sudo}bash -c `"echo '$escaped' >> $Path`""
    }
    return $parts -join ' && '
}

function Wait-Reconnect {
    param([string]$IP, [string]$User, [string]$Pass, [int]$WaitSecs, [int]$Max)
    Write-Step "Waiting ${WaitSecs}s for network to restart on $IP ..."
    Start-Sleep -Seconds $WaitSecs
    for ($i = 1; $i -le $Max; $i++) {
        try {
            Write-Host "     Attempt $i/$Max — connecting to $IP ..." -ForegroundColor DarkGray
            $s = New-SshSessionEx -IP $IP -User $User -Pass $Pass
            Write-Ok "Connected to $IP"
            return $s
        } catch {
            if ($i -lt $Max) { Start-Sleep -Seconds 5 }
        }
    }
    Write-Warn "Could not reconnect to $IP after $Max attempts (verify skipped — config was applied)."
    return $null
}

#endregion

#region ── 1. AHV Host ──────────────────────────────────────────────────────

Write-Header "AHV Host: $AhvCurrentIP  →  $AhvNewIP"

Write-Step "Connecting to AHV ($AhvCurrentIP) as $AhvUsername ..."
$ahv = New-SshSessionEx -IP $AhvCurrentIP -User $AhvUsername -Pass $AhvPassword
Write-Ok "Connected"

# Show current br0 IP (informational)
Write-Step "Reading current br0 address ..."
$curIp = Invoke-Ssh $ahv.SessionId "ip addr show br0 | grep 'inet '"
Write-Host "     $($curIp.Trim())" -ForegroundColor DarkGray

# Step 1: Apply static address and gateway via nmcli modify (persistent, no restart yet)
Write-Step "Applying nmcli static config on br0 ..."
Invoke-Ssh $ahv.SessionId "nmcli con modify br0 ipv4.method manual ipv4.addresses $AhvNewIP/$Prefix ipv4.gateway $Gateway" | Out-Null
Write-Ok "nmcli con modify done"

# Step 2: Bring the connection up in background — SSH will drop when br0 gets the new IP.
# A 3-second sleep gives us time to close the session cleanly before the IP changes.
Write-Step "Bringing br0 up with new IP (SSH will disconnect) ..."
Invoke-Ssh $ahv.SessionId "nohup sh -c 'sleep 3 && nmcli con up br0' >/tmp/nmcli-ip-change.log 2>&1 &" | Out-Null
Write-Ok "nmcli con up scheduled — connection will drop in ~3 s"

Remove-SSHSession -SessionId $ahv.SessionId | Out-Null

# Reconnect to new IP and verify
$ahvNew = Wait-Reconnect -IP $AhvNewIP -User $AhvUsername -Pass $AhvPassword `
          -WaitSecs $ReconnectWaitSeconds -Max $ReconnectAttempts

if ($ahvNew) {
    Write-Step "Verifying AHV IP ..."
    $ipLine = Invoke-Ssh $ahvNew.SessionId "ip addr show br0 | grep 'inet '"
    $hn     = (Invoke-Ssh $ahvNew.SessionId "hostname").Trim()
    $gw     = (Invoke-Ssh $ahvNew.SessionId "ip route show default | head -1").Trim()
    Write-Ok "br0     : $($ipLine.Trim())"
    Write-Ok "Gateway : $gw"
    Write-Ok "Hostname: $hn"
    # Show nmcli log in case something went wrong
    $nmcliLog = Invoke-Ssh $ahvNew.SessionId "cat /tmp/nmcli-ip-change.log 2>/dev/null || true"
    if ($nmcliLog.Trim()) { Write-Host "     nmcli log: $($nmcliLog.Trim())" -ForegroundColor DarkGray }
    Remove-SSHSession -SessionId $ahvNew.SessionId | Out-Null
} else {
    Write-Warn "AHV verify skipped (not reachable at $AhvNewIP) — check nmcli log at /tmp/nmcli-ip-change.log via iLO console"
}

#endregion

#region ── 2. CVM ───────────────────────────────────────────────────────────

Write-Header "CVM: $CvmCurrentIP  →  $CvmNewIP"

Write-Step "Connecting to CVM ($CvmCurrentIP) as $CvmUsername ..."
$cvm = New-SshSessionEx -IP $CvmCurrentIP -User $CvmUsername -Pass $CvmPassword
Write-Ok "Connected"

# Detect which interface holds the current IP
Write-Step "Detecting CVM management interface ..."
$ifaceRaw = Invoke-Ssh $cvm.SessionId "ip addr show | grep '$CvmCurrentIP' | awk '{print \$NF}'"
$cvmIface = $ifaceRaw.Trim()
if (-not $cvmIface) {
    Write-Warn "Could not auto-detect interface — defaulting to eth0"
    $cvmIface = 'eth0'
}
Write-Ok "Interface: $cvmIface"

$cfgPath = "/etc/sysconfig/network-scripts/ifcfg-$cvmIface"

# Show current config
Write-Step "Reading current $cvmIface config ..."
$curCvmCfg = Invoke-Ssh $cvm.SessionId "sudo -n cat $cfgPath 2>/dev/null || cat $cfgPath 2>/dev/null || echo '(file not found)'"
Write-Host $curCvmCfg -ForegroundColor DarkGray

# Preserve DNS
$cvmDnsRaw = Invoke-Ssh $cvm.SessionId "grep '^DNS' $cfgPath 2>/dev/null || true"
$cvmDnsLines = @($cvmDnsRaw.Split("`n") | Where-Object { $_.Trim() })

# Backup — save to /tmp so it is NOT in network-scripts and cannot be picked up
# by the network service as a second interface config with the old IP.
Write-Step "Backing up $cfgPath to /tmp ..."
$ts2 = (Invoke-Ssh $cvm.SessionId "date +%s").Trim()
$backupPath = "/tmp/ifcfg-$cvmIface.bak.$ts2"
Invoke-Ssh $cvm.SessionId "sudo -n cp $cfgPath $backupPath" | Out-Null
Write-Ok "Backup: $backupPath"

# Build new static config lines
$cvmCfgLines = @(
    "DEVICE=$cvmIface",
    "BOOTPROTO=none",
    "ONBOOT=yes",
    "IPADDR=$CvmNewIP",
    "PREFIX=$Prefix",
    "GATEWAY=$Gateway"
) + $cvmDnsLines

# Write config (via sudo tee to avoid permission issues)
Write-Step "Writing static config to $cfgPath ..."

# Build echo >> chain with sudo tee for first line, then append
$firstLine = $cvmCfgLines[0] -replace "'", "'\\'''"
$writeCmd2  = "echo '$firstLine' | sudo -n tee $cfgPath > /dev/null"
Invoke-Ssh $cvm.SessionId $writeCmd2 | Out-Null

for ($i = 1; $i -lt $cvmCfgLines.Count; $i++) {
    $escaped = $cvmCfgLines[$i] -replace "'", "'\\'''"
    Invoke-Ssh $cvm.SessionId "echo '$escaped' | sudo -n tee -a $cfgPath > /dev/null" | Out-Null
}

$writtenCvm = Invoke-Ssh $cvm.SessionId "sudo -n cat $cfgPath"
Write-Host "     New config:" -ForegroundColor DarkGray
Write-Host ($writtenCvm | ForEach-Object { "       $_" }) -ForegroundColor White

# Schedule background restart
Write-Step "Scheduling CVM network restart in background ..."
Invoke-Ssh $cvm.SessionId "nohup sudo -n sh -c 'sleep 3 && systemctl restart network' >/dev/null 2>&1 &" | Out-Null
Write-Ok "Restart scheduled — connection will drop"

Remove-SSHSession -SessionId $cvm.SessionId | Out-Null

# Reconnect and verify
$cvmNew = Wait-Reconnect -IP $CvmNewIP -User $CvmUsername -Pass $CvmPassword `
          -WaitSecs $ReconnectWaitSeconds -Max $ReconnectAttempts

if ($cvmNew) {
    Write-Step "Verifying CVM IP ..."
    $cvmIpLine = Invoke-Ssh $cvmNew.SessionId "ip addr show $cvmIface | grep 'inet '"
    $cvmHn     = (Invoke-Ssh $cvmNew.SessionId "hostname").Trim()
    $cvmGw     = (Invoke-Ssh $cvmNew.SessionId "ip route show default | head -1").Trim()
    Write-Ok "$cvmIface : $($cvmIpLine.Trim())"
    Write-Ok "Gateway  : $cvmGw"
    Write-Ok "Hostname : $cvmHn"

    # Delete the backup file now that we have confirmed the new IP is working.
    # The file is root-owned so nutanix needs sudo to remove it.
    Write-Step "Removing backup file $backupPath ..."
    $rmOut = Invoke-Ssh $cvmNew.SessionId "sudo -n rm -f $backupPath && echo 'deleted' || echo 'failed'"
    if ($rmOut.Trim() -eq 'deleted') {
        Write-Ok "Backup file removed"
    } else {
        Write-Warn "Could not remove $backupPath (sudo rm failed) — delete manually if needed"
    }

    Remove-SSHSession -SessionId $cvmNew.SessionId | Out-Null
} else {
    Write-Warn "CVM verify skipped (not reachable from this host) — config was written, check via iLO console"
}

#endregion

Write-Host ""
Write-Host ('=' * 70) -ForegroundColor Green
Write-Host "  COMPLETE" -ForegroundColor Green
Write-Host "  AHV  : $AhvCurrentIP  →  $AhvNewIP" -ForegroundColor Green
Write-Host "  CVM  : $CvmCurrentIP  →  $CvmNewIP" -ForegroundColor Green
Write-Host "  Mask : /$Prefix,  Gateway: $Gateway" -ForegroundColor Green
Write-Host ('=' * 70) -ForegroundColor Green
Write-Host ""
