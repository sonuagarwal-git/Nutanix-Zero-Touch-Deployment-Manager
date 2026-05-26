#Requires -Version 5.1
<#
.SYNOPSIS
    Queries a Windows DHCP server for active leases in one or more IP scopes.

.DESCRIPTION
    Connects to a Windows DHCP server and lists all active leases in the
    specified scope(s). Output includes client IP, hostname, MAC address,
    lease expiry, and lease state.

    Two connection modes depending on whether credentials are supplied:

      Without credentials:
        Uses Get-DhcpServerv4Lease -ComputerName (RPC/DCOM).
        Requires the DhcpServer RSAT module installed locally and that the
        calling process is running as a domain account with DHCP read rights.

      With credentials (-Credential or -Username):
        Runs Get-DhcpServerv4Lease via Invoke-Command on the DHCP server.
        Requires WinRM to be enabled on the DHCP server. This is the
        recommended mode when calling from NT AUTHORITY\SYSTEM or a
        non-domain context.

.PARAMETER DhcpServer
    IP address or hostname of the Windows DHCP server.

.PARAMETER ScopeId
    One or more scope IDs (subnet base addresses) to query, e.g. '10.0.113.0'.
    Separate multiple scopes with commas.
    If omitted (without -All), all scopes on the server are listed with their
    lease counts — no individual lease details are printed.

.PARAMETER All
    Query and print leases for ALL scopes on the DHCP server.

.PARAMETER Credential
    PSCredential for a DHCP admin or read-only account (e.g. DOMAIN\SVC-NTX-AUTO).

.PARAMETER Username
    Convenience alternative to -Credential. Script prompts for the password.

.EXAMPLE
    # List all scopes on the server (no lease detail)
    .\Query-DhcpLeases.ps1 -DhcpServer 10.0.10.80

.EXAMPLE
    # Query leases in a specific subnet
    .\Query-DhcpLeases.ps1 -DhcpServer 10.0.10.80 -ScopeId 10.0.113.0

.EXAMPLE
    # Query multiple subnets with service account
    .\Query-DhcpLeases.ps1 -DhcpServer 10.0.10.80 -ScopeId 10.0.113.0,10.0.114.0 `
        -Username "DOMAIN\SVC-NTX-AUTO"

.EXAMPLE
    # Query ALL scopes using service account credentials
    .\Query-DhcpLeases.ps1 -DhcpServer 10.0.10.80 -All -Username "DOMAIN\SVC-NTX-AUTO"
#>

[CmdletBinding(DefaultParameterSetName = 'Scope')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$DhcpServer,

    [Parameter(ParameterSetName = 'Scope', Position = 1)]
    [string[]]$ScopeId = @(),

    [Parameter(ParameterSetName = 'All')]
    [switch]$All,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential,

    [string]$Username
)

$ErrorActionPreference = 'Stop'

# Resolve credential from -Username shortcut
if ($Username -and -not $Credential) {
    $Credential = Get-Credential -UserName $Username -Message "Enter password for DHCP account ($Username)"
}

# Import-DhcpModule: loads DhcpServer for PS5.1 direct calls.
function Import-DhcpModule {
    try {
        Import-Module DhcpServer -ErrorAction Stop
    }
    catch {
        Write-Host '  ERROR: DhcpServer PowerShell module not found on this machine.' -ForegroundColor Red
        Write-Host '  Install RSAT:  Add-WindowsCapability -Online -Name Rsat.DHCP.Tools~~~~0.0.1.0' -ForegroundColor Yellow
        throw 'DhcpServer module not available'
    }
}

# Invoke-WinPsBlock: runs $Command in Windows PowerShell 5.1 via EncodedCommand.
# Used on PS7 where DhcpServer -ComputerName RPC calls fail even with -SkipEditionCheck.
# Returns ConvertFrom-Json objects -- properties are plain strings/numbers.
function Invoke-WinPsBlock {
    param([string]$Command)
    $ps5 = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps5)) { throw 'Windows PowerShell 5.1 not found.' }
    $script = @"
`$ErrorActionPreference = 'Stop'
try {
    Import-Module DhcpServer -ErrorAction Stop -WarningAction SilentlyContinue
    $Command | ConvertTo-Json -Depth 4 -Compress -WarningAction SilentlyContinue
} catch {
    '##ERR##' + `$_.Exception.Message
}
"@
    $bytes  = [System.Text.Encoding]::Unicode.GetBytes($script)
    $enc    = [Convert]::ToBase64String($bytes)
    # 2>$null suppresses PS5.1 error stream from printing to console (we capture errors via ##ERR## in stdout)
    $out    = & $ps5 -NoProfile -NonInteractive -EncodedCommand $enc 2>$null
    $errOut = $out | Where-Object { $_ -like '##ERR##*' }
    if ($errOut) { throw ($errOut -replace '^##ERR##') }
    $json = ($out | Where-Object { $_ -notlike '##ERR##*' }) -join ''
    if (-not $json -or $json -eq 'null') { return @() }
    return @($json | ConvertFrom-Json)
}

#region Formatting helpers

function ConvertTo-IpInt {
    param([System.Net.IPAddress]$ip)
    $bytes = $ip.GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function ConvertFrom-IpInt {
    param([uint32]$n)
    $bytes = [BitConverter]::GetBytes($n)
    [Array]::Reverse($bytes)
    return [System.Net.IPAddress]::new($bytes)
}

function Write-Header {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
}

function Write-SubHeader {
    param([string]$Text)
    Write-Host ''
    Write-Host "  -- $Text " -ForegroundColor DarkCyan -NoNewline
    Write-Host ('-' * [Math]::Max(2, 66 - $Text.Length)) -ForegroundColor DarkCyan
}

function Format-LeaseTable {
    param([object[]]$Leases, [string]$ScopeId)

    if (-not $Leases -or $Leases.Count -eq 0) {
        Write-Host "  (no active leases in scope $ScopeId)" -ForegroundColor DarkGray
        return
    }

    # Column widths
    $w = @{ IP = 16; Name = 30; MAC = 19; Expiry = 22; State = 10 }

    # Header row
    $hdr = "  {0,-$($w.IP)} {1,-$($w.Name)} {2,-$($w.MAC)} {3,-$($w.Expiry)} {4,-$($w.State)}" `
           -f 'IP Address', 'Hostname', 'MAC Address', 'Lease Expiry', 'State'
    Write-Host $hdr -ForegroundColor White
    Write-Host ("  " + ('-' * ($w.IP + $w.Name + $w.MAC + $w.Expiry + $w.State + 4))) -ForegroundColor DarkGray

    foreach ($lease in ($Leases | Sort-Object { [System.Version]$_.IPAddress.ToString() })) {
        $ip     = $lease.IPAddress.ToString()
        $name   = if ($lease.HostName)         { $lease.HostName }         else { '-' }
        $mac    = if ($lease.ClientId)         { $lease.ClientId }         else { '-' }
        $expiry = if ($lease.LeaseExpiryTime) {
            try   { ([datetime]$lease.LeaseExpiryTime).ToString('MM/dd/yyyy HH:mm') }
            catch { [string]$lease.LeaseExpiryTime }
        } else { 'Infinite' }
        $state  = if ($lease.AddressState)     { $lease.AddressState }     else { 'Active' }

        # Trim long names
        if ($name.Length -gt ($w.Name - 1))   { $name   = $name.Substring(0, $w.Name - 4)   + '...' }
        if ($mac.Length  -gt ($w.MAC  - 1))   { $mac    = $mac.Substring(0,  $w.MAC  - 4)   + '...' }

        $stateColor = switch -Wildcard ($state) {
            'Active'        { 'Green' }
            'ActiveReservation' { 'Cyan' }
            'Declined'      { 'Red' }
            default         { 'Yellow' }
        }

        $line = "  {0,-$($w.IP)} {1,-$($w.Name)} {2,-$($w.MAC)} {3,-$($w.Expiry)}" `
                -f $ip, $name, $mac, $expiry
        Write-Host $line -NoNewline
        Write-Host (" {0,-$($w.State)}" -f $state) -ForegroundColor $stateColor
    }

    Write-Host ''
    Write-Host ("  Total leases: " + $Leases.Count) -ForegroundColor DarkGray
}

function Format-FreeIpList {
    param(
        [string]$StartRange,
        [string]$EndRange,
        [string[]]$LeasedIps
    )

    $startInt = ConvertTo-IpInt ([System.Net.IPAddress]::Parse($StartRange))
    $endInt   = ConvertTo-IpInt ([System.Net.IPAddress]::Parse($EndRange))
    $total    = $endInt - $startInt + 1

    $freeIps = [System.Collections.Generic.List[string]]::new()
    for ($i = $startInt; $i -le $endInt; $i++) {
        $ip = (ConvertFrom-IpInt $i).ToString()
        if ($LeasedIps -notcontains $ip) {
            $freeIps.Add($ip)
        }
    }

    Write-Host ''
    Write-Host ('  Pool range : {0} - {1}  ({2} addresses)' -f $StartRange, $EndRange, $total) -ForegroundColor DarkGray
    if ($freeIps.Count -eq 0) {
        Write-Host '  Free IPs   : (none - pool is fully leased)' -ForegroundColor Yellow
    }
    else {
        Write-Host "  Free IPs   : $($freeIps.Count) available" -ForegroundColor Green
        Write-Host ''
        # Print in columns of 5
        $cols = 5
        for ($r = 0; $r -lt $freeIps.Count; $r += $cols) {
            $row = $freeIps[$r .. [Math]::Min($r + $cols - 1, $freeIps.Count - 1)]
            Write-Host ('    ' + ($row | ForEach-Object { '{0,-18}' -f $_ }) -join '') -ForegroundColor White
        }
    }
}

#endregion

#region ── Remote execution wrapper ──────────────────────────────────────────

function Invoke-DhcpQuery {
    <#
    .SYNOPSIS
        Runs a script block against the DHCP server.
        Uses Invoke-Command with credentials if -Credential supplied,
        otherwise calls the script block directly relying on the process identity.
    #>
    param(
        [scriptblock]$ScriptBlock,
        [hashtable]$ArgumentList = @{}
    )

    if ($Credential) {
        # Run on the DHCP server over WinRM as the specified account.
        # The DHCP server must have WinRM enabled.
        try {
            $result = Invoke-Command -ComputerName $DhcpServer -Credential $Credential `
                          -ScriptBlock $ScriptBlock -ArgumentList ($ArgumentList.Values) `
                          -ErrorAction Stop
            return $result
        }
        catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
            Write-Host ''
            Write-Host '  ERROR: WinRM connection to DHCP server failed.' -ForegroundColor Red
            Write-Host "  Message: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ''
            Write-Host '  Tip: WinRM must be enabled on the DHCP server.' -ForegroundColor Yellow
            Write-Host '       Run on the DHCP server:  Enable-PSRemoting -Force' -ForegroundColor Yellow
            throw
        }
    }
    else {
        # Direct call — requires DhcpServer RSAT module + domain rights on local machine.
        # Import-DhcpModule handles PS7 compatibility via -SkipEditionCheck.
        Import-DhcpModule
        return & $ScriptBlock @ArgumentList
    }
}

#endregion

#region ── DHCP query functions ──────────────────────────────────────────────

function Get-Scopes {
    if ($Credential) {
        Invoke-Command -ComputerName $DhcpServer -Credential $Credential -ErrorAction Stop -ScriptBlock {
            Get-DhcpServerv4Scope
        }
    }
    else {
        Import-DhcpModule
        Get-DhcpServerv4Scope -ComputerName $DhcpServer -ErrorAction Stop
    }
}

function Get-Leases {
    param([string]$Scope)

    if ($Credential) {
        Invoke-Command -ComputerName $DhcpServer -Credential $Credential -ErrorAction Stop -ScriptBlock {
            param($s) Get-DhcpServerv4Lease -ScopeId $s -ErrorAction Stop
        } -ArgumentList $Scope
    }
    elseif ($PSVersionTable.PSVersion.Major -ge 6) {
        # PS7: DhcpServer RPC calls fail; delegate to Windows PowerShell 5.1
        $cmd = 'Get-DhcpServerv4Lease -ComputerName ''' + $DhcpServer + ''' -ScopeId ''' + $Scope + '''' +
               ' | Select-Object @{N="IPAddress";E={[string]$_.IPAddress}},' +
               '@{N="HostName";E={[string]$_.HostName}},' +
               '@{N="ClientId";E={[string]$_.ClientId}},' +
               '@{N="LeaseExpiryTime";E={if($_.LeaseExpiryTime){$_.LeaseExpiryTime.ToString("o")}else{""}}},' +
               '@{N="AddressState";E={[string]$_.AddressState}}'
        Invoke-WinPsBlock -Command $cmd
    }
    else {
        Import-DhcpModule
        Get-DhcpServerv4Lease -ComputerName $DhcpServer -ScopeId $Scope -ErrorAction Stop
    }
}

function Get-ScopeDetail {
    param([string]$Scope)
    # Returns an object with StartRange and EndRange for the given scope.
    if ($Credential) {
        Invoke-Command -ComputerName $DhcpServer -Credential $Credential -ErrorAction Stop -ScriptBlock {
            param($s)
            Get-DhcpServerv4Scope | Where-Object { $_.ScopeId.ToString() -eq $s } |
                Select-Object ScopeId, StartRange, EndRange, Name
        } -ArgumentList $Scope
    }
    elseif ($PSVersionTable.PSVersion.Major -ge 6) {
        $cmd = 'Get-DhcpServerv4Scope -ComputerName ''' + $DhcpServer + '''' +
               ' | Where-Object { $_.ScopeId.ToString() -eq ''' + $Scope + ''' }' +
               ' | Select-Object @{N="ScopeId";E={[string]$_.ScopeId}},@{N="StartRange";E={[string]$_.StartRange}},@{N="EndRange";E={[string]$_.EndRange}},@{N="Name";E={[string]$_.Name}}'
        $result = Invoke-WinPsBlock -Command $cmd
        if ($result) { $result[0] } else { $null }
    }
    else {
        Import-DhcpModule
        Get-DhcpServerv4Scope -ComputerName $DhcpServer |
            Where-Object { $_.ScopeId.ToString() -eq $Scope } |
            Select-Object ScopeId, StartRange, EndRange, Name
    }
}

function Get-ScopeLeaseCounts {
    # For the "list all scopes" overview: count leases per scope.
    if ($Credential) {
        Invoke-Command -ComputerName $DhcpServer -Credential $Credential -ErrorAction Stop -ScriptBlock {
            Get-DhcpServerv4Scope | ForEach-Object {
                $leases = Get-DhcpServerv4Lease -ScopeId $_.ScopeId -ErrorAction SilentlyContinue
                [PSCustomObject]@{
                    ScopeId     = $_.ScopeId
                    Name        = $_.Name
                    SubnetMask  = $_.SubnetMask
                    State       = $_.State
                    LeaseCount  = @($leases).Count
                }
            }
        }
    }
    elseif ($PSVersionTable.PSVersion.Major -ge 6) {
        $cmd = 'Get-DhcpServerv4Scope -ComputerName ''' + $DhcpServer + '''' +
               ' | ForEach-Object {' +
               ' $l = Get-DhcpServerv4Lease -ComputerName ''' + $DhcpServer + ''' -ScopeId $_.ScopeId -ErrorAction SilentlyContinue;' +
               ' [PSCustomObject]@{ScopeId=[string]$_.ScopeId;Name=[string]$_.Name;SubnetMask=[string]$_.SubnetMask;State=[string]$_.State;LeaseCount=@($l).Count}' +
               ' }'
        Invoke-WinPsBlock -Command $cmd
    }
    else {
        Import-DhcpModule
        Get-DhcpServerv4Scope -ComputerName $DhcpServer | ForEach-Object {
            $leases = Get-DhcpServerv4Lease -ComputerName $DhcpServer -ScopeId $_.ScopeId -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                ScopeId    = $_.ScopeId
                Name       = $_.Name
                SubnetMask = $_.SubnetMask
                State      = $_.State
                LeaseCount = @($leases).Count
            }
        }
    }
}

#endregion

#region ── Main ──────────────────────────────────────────────────────────────

Write-Header "DHCP Lease Query"
Write-Host "  DHCP Server : $DhcpServer" -ForegroundColor White
Write-Host "  Mode        : $(if ($Credential) { "Remote (Invoke-Command as $($Credential.UserName))" } else { "Direct (-ComputerName, process identity)" })" -ForegroundColor White
Write-Host "  Query       : $(if ($All) { 'All scopes' } elseif ($ScopeId.Count -gt 0) { $ScopeId -join ', ' } else { 'List scopes (no lease detail)' })" -ForegroundColor White

# ── Case 1: No scope specified — list all scopes with lease counts ──────────
if (-not $All -and $ScopeId.Count -eq 0) {
    Write-SubHeader "Available Scopes on $DhcpServer"

    try {
        $scopeData = Get-ScopeLeaseCounts

        if (-not $scopeData -or @($scopeData).Count -eq 0) {
            Write-Host "  (no scopes found)" -ForegroundColor DarkGray
        }
        else {
            $w = @{ ID = 16; Name = 28; Mask = 16; State = 10; Count = 10 }
            $hdr = "  {0,-$($w.ID)} {1,-$($w.Name)} {2,-$($w.Mask)} {3,-$($w.State)} {4,-$($w.Count)}" `
                   -f 'Scope ID', 'Name', 'Subnet Mask', 'State', 'Leases'
            Write-Host $hdr -ForegroundColor White
            Write-Host ("  " + ('-' * ($w.ID + $w.Name + $w.Mask + $w.State + $w.Count + 4))) -ForegroundColor DarkGray

            foreach ($scope in ($scopeData | Sort-Object { [System.Version]$_.ScopeId.ToString() })) {
                $countColor = if ($scope.LeaseCount -gt 0) { 'Yellow' } else { 'DarkGray' }
                $stateColor = if ($scope.State -eq 'Active') { 'Green' } else { 'Red' }

                $line = "  {0,-$($w.ID)} {1,-$($w.Name)} {2,-$($w.Mask)}" `
                        -f $scope.ScopeId, $scope.Name, $scope.SubnetMask
                Write-Host $line -NoNewline

                Write-Host (" {0,-$($w.State)}" -f $scope.State) -ForegroundColor $stateColor -NoNewline
                Write-Host (" {0,-$($w.Count)}" -f $scope.LeaseCount) -ForegroundColor $countColor
            }

            Write-Host ''
            Write-Host "  Total scopes: $(@($scopeData).Count)   Total leases: $(($scopeData | Measure-Object -Property LeaseCount -Sum).Sum)" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    Write-Host ''
    Write-Host "  Tip: Re-run with -ScopeId <subnet> to see lease details, or -All for all scopes." -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

# ── Case 2: -All — query every scope ────────────────────────────────────────
if ($All) {
    Write-SubHeader "Loading all scopes from $DhcpServer"
    try {
        if ($Credential) {
            $allScopes = Invoke-Command -ComputerName $DhcpServer -Credential $Credential -ErrorAction Stop -ScriptBlock {
                Get-DhcpServerv4Scope | Select-Object -ExpandProperty ScopeId
            }
        }
        elseif ($PSVersionTable.PSVersion.Major -ge 6) {
            $cmd = 'Get-DhcpServerv4Scope -ComputerName ''' + $DhcpServer + '''' +
                   ' | Select-Object @{N="ScopeId";E={[string]$_.ScopeId}}'
            $allScopes = (Invoke-WinPsBlock -Command $cmd) | ForEach-Object { $_.ScopeId }
        }
        else {
            Import-DhcpModule
            $allScopes = Get-DhcpServerv4Scope -ComputerName $DhcpServer | Select-Object -ExpandProperty ScopeId
        }
        $ScopeId = $allScopes | ForEach-Object { $_.ToString() }
        Write-Host "  Found $($ScopeId.Count) scope(s)." -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  ERROR retrieving scope list: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# -- Case 3: Query leases for each specified scope ────────────────────────────
$grandTotal = 0
$grandFree  = 0

foreach ($scope in $ScopeId) {
    Write-SubHeader "Scope $scope"

    try {
        # Get scope start/end range for free IP calculation
        $detail = Get-ScopeDetail -Scope $scope
        if ($detail) {
            Write-Host "  Name       : $($detail.Name)" -ForegroundColor DarkGray
        }

        $leases = @(Get-Leases -Scope $scope)
        $grandTotal += $leases.Count
        Format-LeaseTable -Leases $leases -ScopeId $scope

        # Show free IPs if we have scope range data
        if ($detail -and $detail.StartRange -and $detail.EndRange) {
            $leasedIpStrings = @($leases | ForEach-Object { $_.IPAddress.ToString() })
            Write-SubHeader "Free IPs in $scope"
            Format-FreeIpList -StartRange $detail.StartRange.ToString() `
                              -EndRange   $detail.EndRange.ToString()   `
                              -LeasedIps  $leasedIpStrings
            $eInt      = ConvertTo-IpInt ([System.Net.IPAddress]::Parse($detail.EndRange.ToString()))
            $sInt      = ConvertTo-IpInt ([System.Net.IPAddress]::Parse($detail.StartRange.ToString()))
            $grandFree += ($eInt - $sInt + 1) - $leases.Count
        }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'not found|invalid|does not exist') {
            Write-Host "  WARNING: Scope '$scope' not found on $DhcpServer." -ForegroundColor Yellow
        }
        elseif ($msg -match 'Failed to get version|access is denied|access denied|unauthorized|privilege' ) {
            Write-Host "  ERROR: Access denied querying DHCP server '$DhcpServer'." -ForegroundColor Red
            Write-Host "  Your account does not have DHCP Administrator rights on this server." -ForegroundColor Yellow
            Write-Host "  Fix: re-run with a privileged account:" -ForegroundColor Yellow
            Write-Host "    .\Query-DhcpLeases.ps1 -DhcpServer $DhcpServer -ScopeId $scope -Username 'DOMAIN\SVC-NTX-AUTO'" -ForegroundColor DarkYellow
        }
        else {
            Write-Host "  ERROR querying scope '$scope': $msg" -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host ('=' * 72) -ForegroundColor Cyan
Write-Host "  Done. Scopes: $($ScopeId.Count)  |  Leased: $grandTotal  |  Free: $grandFree" -ForegroundColor Green
Write-Host ('=' * 72) -ForegroundColor Cyan
Write-Host ''

#endregion
