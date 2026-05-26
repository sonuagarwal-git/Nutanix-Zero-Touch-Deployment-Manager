<#
.SYNOPSIS
    Mounts an ISO image via iLO Redfish API, sets one-time boot to CD, and reboots the server.

.DESCRIPTION
    Supports HPE iLO 5 and iLO 7 via Redfish REST API. After login the script detects
    the iLO generation and discovers the correct VirtualMedia action paths automatically
    (OEM paths for iLO 5, standard Redfish paths for iLO 7):
      1. Eject any existing virtual media in slot 2 (CD/DVD)
      2. Mount an ISO image from a HTTP(S) URL
      3. Set BootOnNextServerReset (HPE OEM) and one-time boot override to Cd (standard Redfish)
      4. Force restart the server so it boots from the mounted ISO
      5. Wait per node for PostState=FinishedPost, then apply a 5-minute buffer
         so Phoenix can fully initialise. The ISO is intentionally left mounted.

    Reads iLO credentials and hostname from the cluster config file under 'network.nodes[]'
    (fields: iLO_ip, iLO_username, iLO_password). The Phoenix ISO URL is read from
    'phoenix_iso_url' in the config, or overridden with -IsoUrl.

.PARAMETER ConfigFile
    Path to the cluster JSON config file (e.g. Configs\my-cluster.json).
    Optional when -IloHost, -IloUsername, -IloPassword and -IsoUrl are supplied directly.

.PARAMETER IloHost
    iLO IP address to target. When used with -ConfigFile, filters to that node only.
    When used without -ConfigFile, this is the single node to process.

.PARAMETER IloUsername
    iLO admin username. Overrides the value from ConfigFile if both are provided.

.PARAMETER IloPassword
    iLO admin password. Overrides the value from ConfigFile if both are provided.

.PARAMETER IsoUrl
    Optional override for the phoenix_iso_url in the config file.

.PARAMETER PostStateTimeoutMinutes
    Maximum minutes to wait per node for PostState=FinishedPost before giving up
    and moving to the next node. After FinishedPost is confirmed a fixed 5-minute
    buffer is applied so Phoenix can copy squashfs.img from the ISO into RAM and
    complete rc.local / service init. The ISO is intentionally NOT ejected —
    Phoenix reads images from it throughout the process.
    Default: 35.

.EXAMPLE
    .\Phonix-Boot.ps1 -ConfigFile .\Configs\my-cluster.json
    Processes all nodes in the cluster config.

.EXAMPLE
    .\Phonix-Boot.ps1 -ConfigFile .\Configs\my-cluster.json -IloHost "10.10.16.120"
    Processes only the node with that iLO IP.

.EXAMPLE
    .\Phonix-Boot.ps1 -ConfigFile .\Configs\my-cluster.json -IsoUrl "https://example.com/phoenix.iso" -PostStateTimeoutMinutes 60
    Override ISO URL and wait up to 60 min per node for FinishedPost.

.EXAMPLE
    # Run without a config file — supply all values manually
    .\Phonix-Boot.ps1 -IloHost "10.10.16.120" -IloUsername "admin" -IloPassword "MyPass!" `
        -IsoUrl "https://example.com/phoenix.iso"

.NOTES
    Author: Sonu Agarwal
    Date: Mar 18, 2026
    Version: 2.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$ConfigFile,
    [string]$IloHost,
    [string]$IloUsername,
    [string]$IloPassword,
    [string]$IsoUrl,
    [int]$PostStateTimeoutMinutes = 35
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Helper Functions ---

function New-IloSession {
    <#
    .SYNOPSIS
        Creates a Redfish session on iLO and returns session headers + session URI for cleanup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IloBase,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Token
    )

    $sessionUri = "$IloBase/redfish/v1/SessionService/Sessions/"
    $body = @{ UserName = $User; Password = $Token } | ConvertTo-Json -Compress

    $response = Invoke-WebRequest -Uri $sessionUri -Method POST -Body $body `
        -ContentType 'application/json' -SkipCertificateCheck -ErrorAction Stop

    $xAuthToken = $response.Headers['X-Auth-Token'] | Select-Object -First 1
    $sessionLocation = $response.Headers['Location'] | Select-Object -First 1

    if (-not $xAuthToken) {
        throw "iLO did not return an X-Auth-Token header."
    }

    # Location may be relative or absolute
    if ($sessionLocation -and $sessionLocation -notmatch '^https?://') {
        $sessionLocation = "$IloBase$sessionLocation"
    }

    return @{
        Headers = @{
            'X-Auth-Token' = $xAuthToken
            'Content-Type' = 'application/json'
            'OData-Version' = '4.0'
        }
        SessionUri = $sessionLocation
    }
}

function Remove-IloSession {
    <#
    .SYNOPSIS
        Closes (deletes) a Redfish session on iLO.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionUri,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    try {
        Invoke-RestMethod -Uri $SessionUri -Method DELETE -Headers $Headers `
            -SkipCertificateCheck -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Session closed" -ForegroundColor Green
    }
    catch {
        Write-Host "  [WARN] Failed to close session: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Invoke-IloApi {
    <#
    .SYNOPSIS
        Wrapper for Invoke-RestMethod with iLO-specific defaults and error handling.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [ValidateSet('GET','POST','PATCH','PUT','DELETE')]
        [string]$Method = 'GET',
        [object]$Body,
        [string]$StepName = 'API call',
        [switch]$IgnoreError
    )

    $params = @{
        Uri                  = $Uri
        Headers              = $Headers
        Method               = $Method
        SkipCertificateCheck = $true
        ErrorAction          = 'Stop'
    }

    if ($Body) {
        if ($Body -is [string]) {
            $params['Body'] = $Body
        } else {
            $params['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress)
        }
    }

    try {
        $response = Invoke-RestMethod @params
        Write-Host "  [OK] $StepName" -ForegroundColor Green
        return $response
    }
    catch {
        $statusCode = $null
        $errorDetail = $_.Exception.Message

        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($IgnoreError) {
            Write-Host "  [SKIP] $StepName ($(if ($statusCode) { "HTTP $statusCode" } else { $errorDetail }))" -ForegroundColor Yellow
            return $null
        }

        Write-Host "  [FAIL] $StepName" -ForegroundColor Red
        if ($statusCode) {
            Write-Host "         HTTP $statusCode — $errorDetail" -ForegroundColor Red
        } else {
            Write-Host "         $errorDetail" -ForegroundColor Red
        }
        throw
    }
}

#endregion

#region --- Main ---

# --- Load cluster config ---
if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }
    try {
        $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    } catch {
        Write-Host "ERROR: Failed to parse config file: $_" -ForegroundColor Red
        exit 1
    }
    # Resolve ISO URL
    $resolvedIsoUrl = if ($IsoUrl) { $IsoUrl } else { $config.phoenix_iso_url }
    if (-not $resolvedIsoUrl) {
        Write-Host "ERROR: No ISO URL specified. Set 'phoenix_iso_url' in the config or pass -IsoUrl." -ForegroundColor Red
        exit 1
    }
    # Build server list from config nodes
    if (-not $config.network -or -not $config.network.nodes -or $config.network.nodes.Count -eq 0) {
        Write-Host "ERROR: No nodes defined in config under 'network.nodes'." -ForegroundColor Red
        exit 1
    }
    $servers = $config.network.nodes | ForEach-Object {
        $nodeUser = if ($IloUsername) { $IloUsername } else { $_.iLO_username }
        $nodePass = if ($IloPassword) { $IloPassword } else { $_.iLO_password }
        if (-not $_.iLO_ip -or -not $nodeUser -or -not $nodePass) {
            Write-Host "WARN: Node '$($_.hostname)' is missing iLO_ip/iLO_username/iLO_password — skipping." -ForegroundColor Yellow
            return
        }
        [PSCustomObject]@{
            iloHost  = $_.iLO_ip
            username = $nodeUser
            password = $nodePass
            hostname = $_.hostname
        }
    } | Where-Object { $_ -ne $null }
    if ($servers.Count -eq 0) {
        Write-Host "ERROR: No valid nodes with iLO credentials found in config." -ForegroundColor Red
        exit 1
    }
    if ($IloHost) {
        $servers = @($servers | Where-Object { $_.iloHost -eq $IloHost })
        if ($servers.Count -eq 0) {
            $available = ($config.network.nodes | Where-Object { $_.iLO_ip } | ForEach-Object { $_.iLO_ip }) -join ', '
            Write-Host "ERROR: iLO host '$IloHost' not found in config nodes. Available: $available" -ForegroundColor Red
            exit 1
        }
    }
} else {
    # Manual mode — all required values must be passed as parameters
    if (-not $IloHost -or -not $IloUsername -or -not $IloPassword -or -not $IsoUrl) {
        Write-Host "ERROR: Provide either -ConfigFile or all of: -IloHost, -IloUsername, -IloPassword, -IsoUrl." -ForegroundColor Red
        exit 1
    }
    $resolvedIsoUrl = $IsoUrl
    $servers = @([PSCustomObject]@{
        iloHost  = $IloHost
        username = $IloUsername
        password = $IloPassword
        hostname = $IloHost
    })
}

Write-Host ""
Write-Host "=== Phoenix Boot — Mount ISO & One-Time Boot ===" -ForegroundColor Cyan
Write-Host "Config  : $ConfigFile"
Write-Host "ISO URL : $resolvedIsoUrl"
Write-Host "Nodes   : $($servers.Count) ($($servers.iloHost -join ', '))"
Write-Host ""

Write-Host "Running Phoenix boot on $($servers.Count) node(s) in parallel..." -ForegroundColor Cyan
Write-Host ""

$results = $servers | ForEach-Object -ThrottleLimit 20 -Parallel {
    # PowerShell -Parallel runspaces cannot receive script blocks via $using:.
    # Re-define the three helpers inline so each runspace has its own copy.

    function New-IloSession {
        param(
            [Parameter(Mandatory)][string]$IloBase,
            [Parameter(Mandatory)][string]$User,
            [Parameter(Mandatory)][string]$Token
        )
        $sessionUri = "$IloBase/redfish/v1/SessionService/Sessions/"
        $body = @{ UserName = $User; Password = $Token } | ConvertTo-Json -Compress
        $response = Invoke-WebRequest -Uri $sessionUri -Method POST -Body $body `
            -ContentType 'application/json' -SkipCertificateCheck -ErrorAction Stop
        $xAuthToken      = $response.Headers['X-Auth-Token'] | Select-Object -First 1
        $sessionLocation = $response.Headers['Location']     | Select-Object -First 1
        if (-not $xAuthToken) { throw "iLO did not return an X-Auth-Token header." }
        if ($sessionLocation -and $sessionLocation -notmatch '^https?://') {
            $sessionLocation = "$IloBase$sessionLocation"
        }
        return @{
            Headers    = @{
                'X-Auth-Token'  = $xAuthToken
                'Content-Type'  = 'application/json'
                'OData-Version' = '4.0'
            }
            SessionUri = $sessionLocation
        }
    }

    function Remove-IloSession {
        param(
            [Parameter(Mandatory)][string]$SessionUri,
            [Parameter(Mandatory)][hashtable]$Headers
        )
        try {
            Invoke-RestMethod -Uri $SessionUri -Method DELETE -Headers $Headers `
                -SkipCertificateCheck -ErrorAction Stop | Out-Null
        } catch { <# best-effort cleanup #> }
    }

    function Invoke-IloApi {
        param(
            [Parameter(Mandatory)][string]$Uri,
            [Parameter(Mandatory)][hashtable]$Headers,
            [ValidateSet('GET','POST','PATCH','PUT','DELETE')]
            [string]$Method = 'GET',
            [object]$Body,
            [string]$StepName = 'API call',
            [switch]$IgnoreError
        )
        $params = @{
            Uri                  = $Uri
            Headers              = $Headers
            Method               = $Method
            SkipCertificateCheck = $true
            ErrorAction          = 'Stop'
        }
        if ($Body) {
            $params['Body'] = if ($Body -is [string]) { $Body } else {
                $Body | ConvertTo-Json -Depth 10 -Compress
            }
        }
        try {
            $response = Invoke-RestMethod @params
            Write-Host "  [OK] $StepName" -ForegroundColor Green
            return $response
        } catch {
            $statusCode  = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
            $errorDetail = $_.Exception.Message
            if ($IgnoreError) {
                Write-Host "  [SKIP] $StepName ($(if ($statusCode) { "HTTP $statusCode" } else { $errorDetail }))" -ForegroundColor Yellow
                return $null
            }
            Write-Host "  [FAIL] $StepName — $(if ($statusCode) { "HTTP $statusCode — " })$errorDetail" -ForegroundColor Red
            throw
        }
    }

    $server                  = $_
    $resolvedIsoUrl          = $using:resolvedIsoUrl
    $PostStateTimeoutMinutes = $using:PostStateTimeoutMinutes
    $iloBase                 = "https://$($server.iloHost)"
    $tag                     = if ($server.hostname) { "[$($server.hostname)]" } else { "[$($server.iloHost)]" }
    $failed                  = $false

    Write-Host "$tag --- Phoenix Boot starting ---" -ForegroundColor Cyan

    $session = $null
    try {
        # Pre-check: Verify that the ISO URL is reachable before touching iLO
        Write-Host "$tag Verifying ISO URL is reachable..." -ForegroundColor DarkGray
        try {
            $isoCheck = Invoke-WebRequest -Uri $resolvedIsoUrl -Method HEAD -UseBasicParsing `
                -TimeoutSec 15 -ErrorAction Stop
            $isoSize = $isoCheck.Headers['Content-Length'] | Select-Object -First 1
            if ($isoSize) {
                $isoSizeMB = [math]::Round([long]$isoSize / 1MB, 1)
                Write-Host "$tag [OK] ISO URL reachable ($isoSizeMB MB)" -ForegroundColor Green
            } else {
                Write-Host "$tag [OK] ISO URL reachable" -ForegroundColor Green
            }
        } catch {
            Write-Host "$tag [FAIL] ISO URL is NOT reachable: $resolvedIsoUrl" -ForegroundColor Red
            Write-Host "$tag        $($_.Exception.Message)" -ForegroundColor Red
            return [PSCustomObject]@{ Hostname = $server.hostname; IloHost = $server.iloHost; Success = $false }
        }

        # Create Redfish session
        $session = New-IloSession -IloBase $iloBase -User $server.username -Token $server.password
        $headers = $session.Headers
        Write-Host "$tag [OK] Session created" -ForegroundColor Green

        # Detect iLO generation
        $iloGenNum = 0
        try {
            $mgr = Invoke-RestMethod -Uri "$iloBase/redfish/v1/Managers/1/" `
                -Headers $headers -Method GET -SkipCertificateCheck -ErrorAction Stop
            if     ($mgr.Model           -match 'iLO\s*(\d+)') { $iloGenNum = [int]$Matches[1] }
            elseif ($mgr.FirmwareVersion  -match '^iLO\s*(\d+)') { $iloGenNum = [int]$Matches[1] }
            Write-Host "$tag [OK] iLO $iloGenNum detected ($($mgr.FirmwareVersion))" -ForegroundColor Green
        } catch {
            Write-Host "$tag [WARN] Could not read iLO version — will attempt path discovery anyway" -ForegroundColor Yellow
        }

        # Discover eject/insert action paths from VirtualMedia slot 2
        # Strategy 1: OEM block (iLO 5)   Strategy 2: Standard Actions block (iLO 7)
        $vmSlotUri = "$iloBase/redfish/v1/Managers/1/VirtualMedia/2/"
        $ejectUri  = $null
        $insertUri = $null
        try {
            $slot = Invoke-RestMethod -Uri $vmSlotUri -Headers $headers `
                -Method GET -SkipCertificateCheck -ErrorAction Stop

            # Strategy 1: OEM block (iLO 5)
            $oemBlock = $slot.Actions.Oem
            if ($oemBlock) {
                foreach ($prop in $oemBlock.PSObject.Properties) {
                    $target = $oemBlock.($prop.Name).'target'
                    if ($prop.Name -match 'Eject'  -and $target -and -not $ejectUri)  { $ejectUri  = if ($target -match '^https?://') { $target } else { "$iloBase$target" } }
                    if ($prop.Name -match 'Insert' -and $target -and -not $insertUri) { $insertUri = if ($target -match '^https?://') { $target } else { "$iloBase$target" } }
                }
            }
            # Strategy 2: Standard Actions block (iLO 7)
            $stdBlock = $slot.Actions
            if ($stdBlock -and (-not $ejectUri -or -not $insertUri)) {
                foreach ($prop in $stdBlock.PSObject.Properties) {
                    if ($prop.Name -eq 'Oem') { continue }
                    $target = $stdBlock.($prop.Name).'target'
                    if ($prop.Name -match 'Eject'  -and $target -and -not $ejectUri)  { $ejectUri  = if ($target -match '^https?://') { $target } else { "$iloBase$target" } }
                    if ($prop.Name -match 'Insert' -and $target -and -not $insertUri) { $insertUri = if ($target -match '^https?://') { $target } else { "$iloBase$target" } }
                }
            }
            if (-not $ejectUri -or -not $insertUri) {
                throw "Could not discover $(if (-not $ejectUri) {'eject'} else {'insert'}) action path from VirtualMedia slot 2 (iLO $iloGenNum)"
            }
            Write-Host "$tag [OK] VirtualMedia action paths discovered" -ForegroundColor Green
            Write-Host "$tag      Eject  : $ejectUri" -ForegroundColor DarkGray
            Write-Host "$tag      Insert : $insertUri" -ForegroundColor DarkGray
        } catch {
            Write-Host "$tag [FAIL] Action path discovery: $($_.Exception.Message)" -ForegroundColor Red
            throw
        }

        # Step 1: Eject existing virtual media (ignore errors — slot may already be empty)
        Invoke-IloApi -Uri $ejectUri -Headers $headers -Method POST -Body @{} `
            -StepName "$tag Eject existing virtual media" -IgnoreError | Out-Null

        # Step 2: Mount ISO
        Invoke-IloApi -Uri $insertUri -Headers $headers -Method POST -Body @{ Image = $resolvedIsoUrl } `
            -StepName "$tag Mount ISO image" | Out-Null

        # Step 3: Set BootOnNextServerReset (HPE OEM flag)
        $vmPatchUri = "$iloBase/redfish/v1/Managers/1/VirtualMedia/2/"
        Invoke-IloApi -Uri $vmPatchUri -Headers $headers -Method PATCH `
            -Body @{ Oem = @{ Hpe = @{ BootOnNextServerReset = $true } } } `
            -StepName "$tag Set BootOnNextServerReset (OEM)" | Out-Null

        # Step 4: Set one-time boot override to Cd (standard Redfish)
        $systemUri = "$iloBase/redfish/v1/Systems/1/"
        Invoke-IloApi -Uri $systemUri -Headers $headers -Method PATCH `
            -Body @{ Boot = @{ BootSourceOverrideTarget = 'Cd'; BootSourceOverrideEnabled = 'Once' } } `
            -StepName "$tag Set one-time boot to Cd" | Out-Null

        # Step 5: Force restart server
        $resetUri = "$iloBase/redfish/v1/Systems/1/Actions/ComputerSystem.Reset/"
        Invoke-IloApi -Uri $resetUri -Headers $headers -Method POST `
            -Body @{ ResetType = 'ForceRestart' } `
            -StepName "$tag Force restart server" | Out-Null

        Write-Host "$tag => Server rebooting — will boot from ISO." -ForegroundColor Green

        # Step 6: Wait for PostState=FinishedPost then 10-min buffer.
        # The ISO is intentionally left mounted — Phoenix continues reading images
        # from /dev/sr0 throughout its process (squashfs copy, injections, image copy).
        $startTime     = Get-Date
        $timeoutEnd    = (Get-Date).AddMinutes($PostStateTimeoutMinutes)
        $pollUri       = "$iloBase/redfish/v1/Systems/1/"
        $imlUri        = "$iloBase/redfish/v1/Systems/1/LogServices/IML/Entries/"
        $seenImlIds    = [System.Collections.Generic.HashSet[string]]::new()
        $postDone      = $false
        $bufferSeconds = 600   # 10 min: squashfs copy into RAM + rc.local + Foundation agent init

        Write-Host "$tag Waiting for PostState=FinishedPost (hard timeout: $PostStateTimeoutMinutes min)..." -ForegroundColor Cyan

        # Seed IML so we only show NEW entries that appear after reboot
        try {
            $existing = Invoke-RestMethod -Uri "$imlUri`?`$top=50" -Headers $headers `
                -Method GET -SkipCertificateCheck -ErrorAction Stop
            foreach ($entry in $existing.Members) { $seenImlIds.Add($entry.Id) | Out-Null }
        } catch {}

        while ((Get-Date) -lt $timeoutEnd) {
            $elapsed    = [int]((Get-Date) - $startTime).TotalSeconds
            $elapsedStr = "$([int]($elapsed/60))m $($elapsed%60)s"

            # Poll PostState
            $postState  = '?'
            $powerState = '?'
            try {
                $system     = Invoke-RestMethod -Uri $pollUri -Headers $headers -Method GET `
                    -SkipCertificateCheck -ErrorAction Stop
                $powerState = $system.PowerState
                $postState  = $system.Oem.Hpe.PostState
                if ($postState -eq 'FinishedPost') { $postDone = $true }
            } catch {
                # iLO unreachable during reboot is normal — keep waiting
            }

            $phase = if (-not $postDone) { 'Waiting for FinishedPost' } else { 'FinishedPost confirmed' }
            Write-Host "$tag [$elapsedStr] Power=$powerState  PostState=$postState  |  $phase" -ForegroundColor DarkGray

            # Poll IML for new log entries since last check
            try {
                $iml = Invoke-RestMethod -Uri "$imlUri`?`$top=20" -Headers $headers `
                    -Method GET -SkipCertificateCheck -ErrorAction Stop
                foreach ($entry in ($iml.Members | Sort-Object Created)) {
                    if ($seenImlIds.Add($entry.Id)) {
                        $sev   = $entry.Severity
                        $color = switch ($sev) {
                            'Critical' { 'Red' }
                            'Warning'  { 'Yellow' }
                            default    { 'Gray' }
                        }
                        Write-Host "$tag [IML] [$sev] $($entry.Message)" -ForegroundColor $color
                    }
                }
            } catch {}

            if ($postDone) {
                Write-Host "$tag [$elapsedStr] FinishedPost confirmed. Waiting 10 min for Phoenix to copy images and start Foundation agent..." -ForegroundColor Green
                # Print progress every 60s during the 10-min ISO buffer wait
                $bufferStart = Get-Date
                $bufferEnd   = $bufferStart.AddSeconds($bufferSeconds)
                while ((Get-Date) -lt $bufferEnd) {
                    $bufRemain = [int](($bufferEnd - (Get-Date)).TotalSeconds)
                    Write-Host "$tag ... ISO copy buffer: ${bufRemain}s remaining" -ForegroundColor DarkGray
                    $sleepFor = [Math]::Min(60, $bufRemain)
                    Start-Sleep -Seconds $sleepFor
                }
                Write-Host "$tag Buffer complete. ISO remains mounted for Foundation Central imaging." -ForegroundColor Cyan
                break
            }

            Start-Sleep -Seconds 30
        }

        if (-not $postDone) {
            $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
            Write-Host "$tag [WARN] Hard timeout after $([int]($elapsed/60))m without FinishedPost — Phoenix may not have booted correctly." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "$tag => FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $failed = $true
    }
    finally {
        if ($session -and $session.SessionUri) {
            Remove-IloSession -SessionUri $session.SessionUri -Headers $session.Headers
        }
    }

    return [PSCustomObject]@{ Hostname = $server.hostname; IloHost = $server.iloHost; Success = (-not $failed) }
}

# --- Summary ---
# @() forces array so .Count is always valid under Set-StrictMode -Version Latest
# (without it, $null.Count throws when all nodes succeed and Where-Object returns nothing)
$failCount    = @($results | Where-Object { -not $_.Success }).Count
$successCount = $servers.Count - $failCount
Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
Write-Host "Success: $successCount / $($servers.Count)"
if ($failCount -gt 0) {
    Write-Host "Failed : $failCount / $($servers.Count)" -ForegroundColor Red
    exit 1
}

exit 0

#endregion
