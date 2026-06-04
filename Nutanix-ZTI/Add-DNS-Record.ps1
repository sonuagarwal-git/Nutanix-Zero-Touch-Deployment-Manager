#Requires -Version 5.1
<#
.SYNOPSIS
    Creates DNS A records for Nutanix cluster nodes and VIP from a ZTD config file.
.DESCRIPTION
    Reads a ZTD cluster config JSON and creates three sets of DNS A records per DNS server:

      1. Node hypervisor records : <hostname>  -> hypervisor_ip   in <domain>.net
      2. Node iLO records        : <hostname>i -> iLO_ip          in <domain>.ilo
      3. Cluster VIP record      : <clusterName> -> cluster_vip   in <domain>.net

    DNS admin credentials are read from the config file's optional 'dns_admin' section
    (fields: username, password). When present, DNS cmdlets run via Invoke-Command on the
    primary DNS server as that account — allowing the pipeline service (NT AUTHORITY\SYSTEM)
    to delegate DNS operations to a domain account with the required rights.

    If no dns_admin is configured, the script falls back to the calling process identity
    (works when run interactively as a domain DNS admin).

.PARAMETER ConfigFile
    Path to a ZTD cluster config JSON.
.PARAMETER DnsServers
    One or more DNS server IP addresses. Defaults to dns_servers from the config.
.PARAMETER NetZone
    Forward DNS zone for hypervisor and cluster VIP records. Default: 'company.net'.
.PARAMETER IloZone
    Forward DNS zone for iLO records. Default: 'company.ilo'.
.PARAMETER Credential
    PSCredential for the DNS service account (overrides dns_admin in config).
.PARAMETER Username
    Convenience alternative to -Credential. Script prompts for password.
.EXAMPLE
    .\Add-DNS-Record.ps1 -ConfigFile .\Configs\my-cluster.json
.EXAMPLE
    $cred = Get-Credential "DOMAIN\SVC-NTX-AUTO"
    .\Add-DNS-Record.ps1 -ConfigFile .\Configs\my-cluster.json -Credential $cred
.EXAMPLE
    .\Add-DNS-Record.ps1 -ConfigFile .\Configs\my-cluster.json -Username "DOMAIN\SVC-NTX-AUTO"

.NOTES
    Author: Sonu Agarwal
    Date: Mar 28, 2026
    Version: 1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [string[]]$DnsServers = @(),

    [string]$NetZone = 'company.net',

    [string]$IloZone = 'company.ilo',

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential,

    [string]$Username
)

$ErrorActionPreference = 'Stop'

if ($Username -and -not $Credential) {
    $Credential = Get-Credential -UserName $Username -Message "Enter password for DNS service account ($Username)"
}

# Tracks whether any record creation genuinely failed (distinguished from skipped/already-exists)
$script:anyCreationFailed = $false

# The credential used for DNS RPC/DCOM operations (set later after config is loaded)
$script:DnsCred = $null

#region Helper Functions

function Write-Result {
    param(
        [string]$Type,
        [string]$Query,
        [string]$DnsServer,
        [string]$Result,
        [bool]$Success
    )
    $color  = if ($Success) { 'Green' } else { 'Red' }
    $symbol = if ($Success) { [char]0x2713 } else { [char]0x2717 }
    Write-Host ("  {0} [{1}] {2,-55} -> {3} (via {4})" -f $symbol, $Type, $Query, $Result, $DnsServer) -ForegroundColor $color
}

# Load Win32 helper to spawn dnscmd as a specific user via LogonUser +
# DuplicateTokenEx + CreateProcessAsUser. This is the only method that works
# from NT AUTHORITY\SYSTEM — CreateProcessWithLogonW is explicitly blocked for SYSTEM.
if (-not ([System.Management.Automation.PSTypeName]'DnsCmdHelper').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.ComponentModel;
using System.Text;

public static class DnsCmdHelper {
    const int  LOGON32_LOGON_NEW_CREDENTIALS = 9;
    const int  LOGON32_PROVIDER_DEFAULT      = 0;
    const int  STARTF_USESTDHANDLES          = 0x100;
    const uint CREATE_NO_WINDOW              = 0x08000000;
    const uint INFINITE                      = 0xFFFFFFFF;
    const int  HANDLE_FLAG_INHERIT           = 1;
    const int  TOKEN_ALL_ACCESS              = 0x000F01FF;
    const int  SecurityImpersonation         = 2;
    const int  TokenPrimary                  = 1;

    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES {
        public int nLength; public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION {
        public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId;
    }

    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool LogonUser(string user, string domain, string pass, int type, int provider, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool DuplicateTokenEx(IntPtr src, int access, IntPtr attr, int imp, int tokenType, out IntPtr dst);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool CreateProcessAsUser(IntPtr token, string app, string cmd,
        ref SECURITY_ATTRIBUTES psa, ref SECURITY_ATTRIBUTES tsa,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CreatePipe(out IntPtr r, out IntPtr w, ref SECURITY_ATTRIBUTES sa, uint sz);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetHandleInformation(IntPtr h, int mask, int val);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadFile(IntPtr h, byte[] buf, uint n, out uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h, out uint ex);

    static string ReadAll(IntPtr pipe) {
        var ms = new MemoryStream(); var buf = new byte[4096]; uint r;
        while (ReadFile(pipe, buf, (uint)buf.Length, out r, IntPtr.Zero) && r > 0) ms.Write(buf, 0, (int)r);
        return Encoding.Default.GetString(ms.ToArray());
    }

    public static DnsCmdResult Run(string username, string domain, string password, string args) {
        IntPtr tok = IntPtr.Zero, pri = IntPtr.Zero;
        if (!LogonUser(username, domain, password, LOGON32_LOGON_NEW_CREDENTIALS, LOGON32_PROVIDER_DEFAULT, out tok))
            return new DnsCmdResult { ExitCode = 1, Output = "LogonUser failed: " + new Win32Exception().Message };
        try {
            if (!DuplicateTokenEx(tok, TOKEN_ALL_ACCESS, IntPtr.Zero, SecurityImpersonation, TokenPrimary, out pri))
                return new DnsCmdResult { ExitCode = 1, Output = "DuplicateTokenEx failed: " + new Win32Exception().Message };
            var pipeSa = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), bInheritHandle = true };
            var psa    = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)) };
            var tsa    = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)) };
            IntPtr or, ow, er, ew;
            CreatePipe(out or, out ow, ref pipeSa, 0);
            CreatePipe(out er, out ew, ref pipeSa, 0);
            SetHandleInformation(or, HANDLE_FLAG_INHERIT, 0);
            SetHandleInformation(er, HANDLE_FLAG_INHERIT, 0);
            var si = new STARTUPINFO {
                cb = Marshal.SizeOf(typeof(STARTUPINFO)),
                dwFlags = STARTF_USESTDHANDLES,
                hStdInput = IntPtr.Zero, hStdOutput = ow, hStdError = ew
            };
            PROCESS_INFORMATION pi;
            bool ok = CreateProcessAsUser(pri, null, "dnscmd.exe " + args, ref psa, ref tsa, true,
                CREATE_NO_WINDOW, IntPtr.Zero, @"C:\Windows\System32", ref si, out pi);
            CloseHandle(ow); CloseHandle(ew);
            if (!ok) { CloseHandle(or); CloseHandle(er);
                return new DnsCmdResult { ExitCode = 1, Output = "CreateProcessAsUser failed: " + new Win32Exception().Message }; }
            string output = ReadAll(or) + ReadAll(er);
            WaitForSingleObject(pi.hProcess, INFINITE);
            uint exit; GetExitCodeProcess(pi.hProcess, out exit);
            CloseHandle(pi.hProcess); CloseHandle(pi.hThread); CloseHandle(or); CloseHandle(er);
            return new DnsCmdResult { ExitCode = (int)exit, Output = output.Trim() };
        } finally {
            if (tok != IntPtr.Zero) CloseHandle(tok);
            if (pri != IntPtr.Zero) CloseHandle(pri);
        }
    }
}
public class DnsCmdResult { public int ExitCode; public string Output; }
'@
}

function Invoke-DnsCmd {
    param([string[]]$Arguments)

    if ($script:DnsCred) {
        $netCred = $script:DnsCred.GetNetworkCredential()
        $argStr  = ($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
        $result  = [DnsCmdHelper]::Run($netCred.UserName, $netCred.Domain, $netCred.Password, $argStr)
        return [PSCustomObject]@{
            ExitCode = $result.ExitCode
            Output   = $result.Output
            Success  = ($result.ExitCode -eq 0)
        }
    }

    $output = & dnscmd @Arguments 2>&1
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output -join "`n").Trim()
        Success  = ($LASTEXITCODE -eq 0)
    }
}

function New-DNSARecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][string]$ZoneName,
        [Parameter(Mandatory)][string]$DnsServer
    )
    $recordName   = $Hostname -replace "\.$([regex]::Escape($ZoneName))$", ''
    $fqdn         = "$recordName.$ZoneName"
    $displayQuery = "$fqdn -> $IPAddress"

    # Pre-check: does the A record already exist?
    $check = Invoke-DnsCmd -Arguments @($DnsServer, '/enumrecords', $ZoneName, $recordName)
    if ($check.Success) {
        $existingIPs = @($check.Output -split "`n" | Where-Object { $_ -match '\bA\b' } |
                         ForEach-Object { if ($_ -match '(\d+\.\d+\.\d+\.\d+)') { $matches[1] } })
        if ($existingIPs -contains $IPAddress) {
            Write-Host ("  - [A  ] {0,-55} -> Already exists with correct IP (skipped)" -f $displayQuery) -ForegroundColor DarkGray
        } else {
            Write-Host ("  ! [A  ] {0,-55} -> WARNING: Record exists with different IP: {1} (skipped)" -f $displayQuery, ($existingIPs -join ', ')) -ForegroundColor Yellow
        }
        return
    }

    # Create A record
    $create = Invoke-DnsCmd -Arguments @($DnsServer, '/recordadd', $ZoneName, $recordName, 'A', $IPAddress)
    if ($create.Success) {
        Write-Result -Type 'A  ' -Query $displayQuery -DnsServer $DnsServer -Result 'Created (A)' -Success $true
        # PTR: use class A reverse zone (e.g. 10.in-addr.arpa), name = last-three-octets reversed
        # e.g. 10.10.10.144 -> zone=10.in-addr.arpa, name=144.10.10 -> FQDN=144.10.10.10.in-addr.arpa
        $octets  = $IPAddress -split '\.'
        $revZone = "$($octets[0]).in-addr.arpa"
        $ptrName = "$($octets[3]).$($octets[2]).$($octets[1])"
        $ptr = Invoke-DnsCmd -Arguments @($DnsServer, '/recordadd', $revZone, $ptrName, 'PTR', "$fqdn.")
        if ($ptr.Success) {
            Write-Host "          + PTR $ptrName added in $revZone" -ForegroundColor DarkGray
        } else {
            Write-Host "          ! PTR not created in $revZone — $($ptr.Output)" -ForegroundColor Yellow
        }
    } else {
        # DNS_ERROR_RECORD_ALREADY_EXISTS means pre-check missed it — treat as skip, not failure
        if ($create.Output -match 'DNS_ERROR_RECORD_ALREADY_EXISTS|9711|0x25EF') {
            Write-Host ("  - [A  ] {0,-55} -> Already exists (skipped)" -f $displayQuery) -ForegroundColor DarkGray
        } else {
            Write-Result -Type 'A  ' -Query $displayQuery -DnsServer $DnsServer -Result $create.Output -Success $false
            $script:anyCreationFailed = $true
        }
    }
}
function Invoke-PostCheck {
    <#
    .SYNOPSIS
        After creation, resolves each FQDN (forward A) and each IP (reverse PTR)
        against the primary DNS server to confirm records are live.
    #>
    param(
        [Parameter(Mandatory)][string]$DnsServer,
        [object[]]$Records   # array of @{FQDN; IP}
    )
    Write-Host ''
    Write-Host '--- Post-creation verification ---' -ForegroundColor White
    foreach ($r in $Records) {
        # Forward A check
        try {
            $a = Resolve-DnsName -Name $r.FQDN -Type A -Server $DnsServer -DnsOnly -ErrorAction Stop |
                 Where-Object { $_.QueryType -eq 'A' }
            $resolvedIPs = @($a.IPAddress)
            if ($resolvedIPs -contains $r.IP) {
                Write-Result -Type 'A  ' -Query $r.FQDN -DnsServer $DnsServer -Result ($resolvedIPs -join ', ') -Success $true
            } else {
                Write-Result -Type 'A  ' -Query $r.FQDN -DnsServer $DnsServer -Result "Resolved to $($resolvedIPs -join ', ') — expected $($r.IP)" -Success $false
            }
        }
        catch {
            Write-Result -Type 'A  ' -Query $r.FQDN -DnsServer $DnsServer -Result $_.Exception.Message -Success $false
        }
        # Reverse PTR check
        try {
            $ptr = Resolve-DnsName -Name $r.IP -Type PTR -Server $DnsServer -DnsOnly -ErrorAction Stop |
                   Where-Object { $_.QueryType -eq 'PTR' }
            $names = @($ptr.NameHost)
            if ($names.Count -gt 0) {
                Write-Result -Type 'PTR' -Query $r.IP -DnsServer $DnsServer -Result ($names -join ', ') -Success $true
            } else {
                Write-Result -Type 'PTR' -Query $r.IP -DnsServer $DnsServer -Result 'No PTR record found' -Success $false
            }
        }
        catch {
            Write-Result -Type 'PTR' -Query $r.IP -DnsServer $DnsServer -Result $_.Exception.Message -Success $false
        }
    }
}

#endregion

#region Main Execution

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '                    Add DNS Records                           ' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host "  Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor DarkGray

# --- Load and validate config ---
if (-not (Test-Path $ConfigFile)) {
    Write-Host "Config file not found: $ConfigFile" -ForegroundColor Red
    exit 1
}
try { $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json }
catch {
    Write-Host "Failed to parse config JSON: $_" -ForegroundColor Red
    exit 1
}

if ($DnsServers.Count -eq 0 -and $cfg.dns_servers) {
    $DnsServers = @($cfg.dns_servers)
}
if ($DnsServers.Count -eq 0) {
    Write-Host 'No DNS servers found. Specify -DnsServers or add dns_servers to the config.' -ForegroundColor Red
    exit 1
}

# Resolve any IP addresses in $DnsServers to hostnames via reverse PTR lookup.
# dnscmd requires a reachable hostname or FQDN — IPs work sometimes but PTR resolution
# ensures the correct server name is used for RPC authentication.
$DnsServers = @($DnsServers | ForEach-Object {
    $entry = $_
    if ($entry -match '^\d+\.\d+\.\d+\.\d+$') {
        try {
            $ptr = Resolve-DnsName -Name $entry -Type PTR -ErrorAction Stop | Where-Object { $_.QueryType -eq 'PTR' } | Select-Object -First 1
            if ($ptr) {
                $hostname = $ptr.NameHost.TrimEnd('.')
                Write-Host "  Resolved DNS server $entry -> $hostname" -ForegroundColor DarkGray
                $hostname
            } else { $entry }
        } catch { $entry }
    } else { $entry }
})

$clusterName = $cfg.clusterName
$clusterVip  = $cfg.network.cluster_vip
$nodes       = @($cfg.network.nodes)

if (-not $clusterVip) {
    Write-Host 'ERROR: cluster_vip not found in config network section.' -ForegroundColor Red
    exit 1
}
if ($nodes.Count -eq 0) {
    Write-Host 'ERROR: No nodes found in config network.nodes.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host "Config:      $ConfigFile"           -ForegroundColor White
Write-Host "Cluster:     $clusterName"           -ForegroundColor White
Write-Host "Cluster VIP: $clusterVip"            -ForegroundColor White
Write-Host "Nodes:       $($nodes.Count)"        -ForegroundColor White
Write-Host "DNS servers: $($DnsServers -join ', ')" -ForegroundColor White
Write-Host "Primary DNS: $($DnsServers[0]) (records created here; secondaries replicate automatically)" -ForegroundColor DarkGray
Write-Host "Net zone:    $NetZone"               -ForegroundColor White
Write-Host "iLO zone:    $IloZone"               -ForegroundColor White

# --- Set DNS credential ---
# Priority: -Credential param > -Username param > config dns_admin section > process identity
if (-not $Credential -and $cfg.dns_admin -and $cfg.dns_admin.username -and $cfg.dns_admin.password) {
    $secPwd  = ConvertTo-SecureString $cfg.dns_admin.password -AsPlainText -Force
    $fullUser = if ($cfg.dns_admin.domain) { "$($cfg.dns_admin.domain)\$($cfg.dns_admin.username)" } else { $cfg.dns_admin.username }
    $Credential = New-Object System.Management.Automation.PSCredential($fullUser, $secPwd)
}

if ($Credential) {
    $script:DnsCred = $Credential
    Write-Host "DNS credential: $($Credential.UserName) (dnscmd will run as this account)" -ForegroundColor White
} else {
    $callerIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($callerIdentity -match '^NT AUTHORITY') {
        Write-Host ''
        Write-Host '  WARNING: Running as NT AUTHORITY\SYSTEM. Pass -Credential or -Username' -ForegroundColor Yellow
        Write-Host '  with a DNS admin account so dnscmd can authenticate to the DNS server.' -ForegroundColor Yellow
    }
    Write-Host "DNS credential: none (using process identity: $callerIdentity)" -ForegroundColor DarkGray
}
Write-Host ''

# Preview the records that will be created
Write-Host 'Records to create:' -ForegroundColor White
foreach ($node in $nodes) {
    Write-Host ("  {0,-30} -> {1,-18} [{2}]" -f $node.hostname,        $node.hypervisor_ip, $NetZone) -ForegroundColor DarkGray
    Write-Host ("  {0,-30} -> {1,-18} [{2}]" -f ($node.hostname + 'i'), $node.iLO_ip,        $IloZone) -ForegroundColor DarkGray
}
Write-Host ("  {0,-30} -> {1,-18} [{2}]" -f $clusterName, $clusterVip, $NetZone) -ForegroundColor DarkGray
Write-Host ''

# --- Create records on the primary DNS server only ---
# Secondaries replicate automatically via zone transfer.
$primaryDns = $DnsServers[0]
Write-Host "DNS Server: $primaryDns" -ForegroundColor Cyan
Write-Host ('-' * 70) -ForegroundColor DarkGray

# Verify dnscmd.exe is available
if (-not (Get-Command 'dnscmd.exe' -ErrorAction SilentlyContinue)) {
    Write-Host 'ERROR: dnscmd.exe not found. Install DNS RSAT tools:' -ForegroundColor Red
    Write-Host '  Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0' -ForegroundColor Yellow
    exit 1
}

# Build a flat list of all records for post-check
$allRecords = [System.Collections.Generic.List[hashtable]]::new()

Write-Host "  [$NetZone] Node hypervisor records:" -ForegroundColor White
foreach ($node in $nodes) {
    New-DNSARecord -Hostname $node.hostname -IPAddress $node.hypervisor_ip -ZoneName $NetZone -DnsServer $primaryDns
    $allRecords.Add(@{ FQDN = "$($node.hostname).$NetZone"; IP = $node.hypervisor_ip })
}

Write-Host ''
Write-Host "  [$IloZone] Node iLO records:" -ForegroundColor White
foreach ($node in $nodes) {
    New-DNSARecord -Hostname ($node.hostname + 'i') -IPAddress $node.iLO_ip -ZoneName $IloZone -DnsServer $primaryDns
    $allRecords.Add(@{ FQDN = "$($node.hostname)i.$IloZone"; IP = $node.iLO_ip })
}

Write-Host ''
Write-Host "  [$NetZone] Cluster VIP record:" -ForegroundColor White
New-DNSARecord -Hostname $clusterName -IPAddress $clusterVip -ZoneName $NetZone -DnsServer $primaryDns
$allRecords.Add(@{ FQDN = "$clusterName.$NetZone"; IP = $clusterVip })

# --- Post-creation verification ---
Invoke-PostCheck -DnsServer $primaryDns -Records $allRecords

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '  DNS record creation complete.' -ForegroundColor Green
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

# Exit 1 only if genuine creation failures occurred.
# Already-exists skips and warnings are NOT failures.
if ($script:anyCreationFailed) { exit 1 } else { exit 0 }

#endregion
