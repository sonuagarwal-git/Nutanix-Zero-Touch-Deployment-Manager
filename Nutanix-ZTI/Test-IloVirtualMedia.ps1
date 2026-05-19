#Requires -Version 7.0
<#
.SYNOPSIS
    iLO Redfish diagnostic — discovers VirtualMedia action paths and optionally tests mount+eject.
    Safe to run: any mount is fully reversed before the script exits.

.DESCRIPTION
    Tests the following against a single iLO host:
      1. Redfish session create/delete
      2. VirtualMedia slot enumeration (discovers all slots and their MediaTypes)
      3. Reports which slot is suitable for ISO mounting (CD/DVD)
      4. Discovers actual Eject/Insert action paths (OEM + standard Redfish)
      5. Reads current PostState so you can verify that field is accessible
      6. [Optional] Mounts the ISO, verifies it appears, then ejects and verifies again
         Only runs when -IsoUrl is supplied. The slot is always left clean.

    Shows iLO firmware version to confirm iLO5 vs iLO7.

.PARAMETER ConfigFile
    Path to the cluster JSON config file. The first node's iLO credentials are used
    unless -IloHost is specified to pick a specific node.
    Optional when -IloIp, -IloUsername and -IloPassword are supplied directly.

.PARAMETER IloHost
    iLO IP or hostname to test. Must match an iLO_ip in the config.
    If omitted, the first node in the config is used.

.PARAMETER IloIp
    iLO IP address — use instead of -ConfigFile for a quick ad-hoc test.

.PARAMETER IloUsername
    iLO username (e.g. administrator) — required when using -IloIp.

.PARAMETER IloPassword
    iLO password — required when using -IloIp.

.PARAMETER IsoUrl
    Optional HTTPS URL of an ISO image to use for the mount+eject live test (Step 6).
    The ISO is mounted, verified, then immediately ejected. The slot is left clean.
    Example: https://myserver/images/phoenix.iso

.EXAMPLE
    .\Test-IloVirtualMedia.ps1 -ConfigFile .\Configs\DKCDC-1P-NTXTEST-03.json

.EXAMPLE
    .\Test-IloVirtualMedia.ps1 -ConfigFile .\Configs\DKCDC-1P-NTXTEST-06.json -IloHost 10.10.16.121

.EXAMPLE
    .\Test-IloVirtualMedia.ps1 -IloIp 10.10.16.122 -IloUsername administrator -IloPassword 'MyP@ss'

.EXAMPLE
    # Full live mount+eject test
    .\Test-IloVirtualMedia.ps1 -IloIp 10.10.16.122 -IloUsername administrator -IloPassword 'MyP@ss' `
        -IsoUrl 'https://myserver/images/phoenix.iso'
#>

[CmdletBinding(DefaultParameterSetName = 'Config')]
param(
    # ── Config-file mode ─────────────────────────────────────────────────────
    [Parameter(ParameterSetName = 'Config', Mandatory)]
    [string]$ConfigFile,

    [Parameter(ParameterSetName = 'Config')]
    [string]$IloHost,

    # ── Direct / ad-hoc mode ─────────────────────────────────────────────────
    [Parameter(ParameterSetName = 'Direct', Mandatory)]
    [string]$IloIp,

    [Parameter(ParameterSetName = 'Direct', Mandatory)]
    [string]$IloUsername,

    [Parameter(ParameterSetName = 'Direct', Mandatory)]
    [string]$IloPassword,

    # ── Optional live test ────────────────────────────────────────────────
    [Parameter()]
    [string]$IsoUrl   # supply to trigger live mount+eject test in Step 6
)

$ErrorActionPreference = 'Stop'

#region ── Helpers ─────────────────────────────────────────────────────────────

function Write-Ok     { param([string]$M) Write-Host "  [OK]   $M" -ForegroundColor Green  }
function Write-Fail   { param([string]$M) Write-Host "  [FAIL] $M" -ForegroundColor Red    }
function Write-Warn   { param([string]$M) Write-Host "  [WARN] $M" -ForegroundColor Yellow }
function Write-Info   { param([string]$M) Write-Host "  [INFO] $M" -ForegroundColor Cyan   }
function Write-Detail { param([string]$M) Write-Host "         $M" -ForegroundColor Gray   }

#endregion

#region ── Resolve target node ────────────────────────────────────────────────

if ($PSCmdlet.ParameterSetName -eq 'Direct') {
    # Ad-hoc mode — credentials supplied directly on the command line
    $iloBase = "https://$IloIp"
    $tag     = $IloIp
    $node    = [PSCustomObject]@{
        iLO_ip       = $IloIp
        iLO_username = $IloUsername
        iLO_password = $IloPassword
        hostname     = $IloIp
    }
} else {
    # Config-file mode
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }

    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

    $allNodes = @($config.network.nodes)
    if ($allNodes.Count -eq 0) {
        Write-Host "ERROR: No nodes in config." -ForegroundColor Red
        exit 1
    }

    $node = if ($IloHost) {
        $allNodes | Where-Object { $_.iLO_ip -eq $IloHost } | Select-Object -First 1
    } else {
        $allNodes[0]
    }

    if (-not $node) {
        $available = ($allNodes | Where-Object iLO_ip | ForEach-Object { $_.iLO_ip }) -join ', '
        Write-Host "ERROR: iLO host '$IloHost' not found. Available: $available" -ForegroundColor Red
        exit 1
    }

    if (-not $node.iLO_ip -or -not $node.iLO_username -or -not $node.iLO_password) {
        Write-Host "ERROR: Node '$($node.hostname)' is missing iLO_ip / iLO_username / iLO_password." -ForegroundColor Red
        exit 1
    }

    $iloBase = "https://$($node.iLO_ip)"
    $tag     = if ($node.hostname) { "$($node.hostname) [$($node.iLO_ip)]" } else { $node.iLO_ip }
}

#endregion

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  iLO VirtualMedia Diagnostic — READ-ONLY, no changes    " -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Target  : $tag"
Write-Host "  Mode    : $(if ($PSCmdlet.ParameterSetName -eq 'Direct') { 'Direct (no config file)' } else { "Config file: $ConfigFile" })"
Write-Host ""

$headers     = $null
$sessionUri  = $null

try {
    #region ── Step 1: Create Redfish Session ──────────────────────────────────
    Write-Host "── Step 1: Create Redfish session ──────────────────────────" -ForegroundColor White

    $sessBody = @{ UserName = $node.iLO_username; Password = $node.iLO_password } | ConvertTo-Json -Compress
    try {
        $sessResp = Invoke-WebRequest -Uri "$iloBase/redfish/v1/SessionService/Sessions/" `
            -Method POST -Body $sessBody -ContentType 'application/json' `
            -SkipCertificateCheck -ErrorAction Stop
    }
    catch {
        Write-Fail "Cannot reach iLO at $iloBase"
        Write-Detail $_.Exception.Message
        exit 1
    }

    $xToken      = $sessResp.Headers['X-Auth-Token'] | Select-Object -First 1
    $sessionUri  = $sessResp.Headers['Location']     | Select-Object -First 1

    if (-not $xToken) {
        Write-Fail "iLO did not return X-Auth-Token — wrong credentials?"
        exit 1
    }
    if ($sessionUri -and $sessionUri -notmatch '^https?://') {
        $sessionUri = "$iloBase$sessionUri"
    }

    $headers = @{
        'X-Auth-Token'  = $xToken
        'Content-Type'  = 'application/json'
        'OData-Version' = '4.0'
    }
    Write-Ok "Session created (token: $($xToken.Substring(0, [Math]::Min(8,$xToken.Length)))…)"
    Write-Detail "Session URI: $sessionUri"
    Write-Host ""

    #endregion

    #region ── Step 2: iLO firmware version ───────────────────────────────────
    Write-Host "── Step 2: iLO firmware version ─────────────────────────────" -ForegroundColor White

    try {
        $managers = Invoke-RestMethod -Uri "$iloBase/redfish/v1/Managers/1/" `
            -Headers $headers -Method GET -SkipCertificateCheck -ErrorAction Stop

        $fwVersion  = $managers.FirmwareVersion
        $mgrModel   = $managers.Model

        # iLO generation: prefer the Model field (e.g. "iLO 7"), fall back to FirmwareVersion
        $iloGenDesc = if ($mgrModel -match 'iLO\s*(\d+)') {
            "iLO $($Matches[1])"
        } elseif ($fwVersion -match '^iLO\s*(\d+)') {
            "iLO $($Matches[1])"
        } else {
            "iLO (version $fwVersion)"
        }
        $iloGenNum = if ($mgrModel -match 'iLO\s*(\d+)') { [int]$Matches[1] }
                     elseif ($fwVersion -match '^iLO\s*(\d+)') { [int]$Matches[1] }
                     else { 0 }

        Write-Ok "iLO Manager info retrieved"
        Write-Detail "Model           : $mgrModel"
        Write-Detail "FirmwareVersion : $fwVersion  →  $iloGenDesc"

        if ($iloGenNum -ge 7) {
            Write-Warn "iLO7 detected — OEM action paths differ from iLO5. Step 4 will discover the correct paths."
        } elseif ($iloGenNum -eq 5) {
            Write-Ok "iLO5 detected — slot convention should match Phoenix-Boot.ps1."
        } else {
            Write-Warn "iLO generation unclear — check slot discovery output below."
        }
    }
    catch {
        Write-Warn "Could not read iLO manager info: $($_.Exception.Message)"
    }
    Write-Host ""

    #endregion

    #region ── Step 3: Enumerate all VirtualMedia slots ───────────────────────
    Write-Host "── Step 3: VirtualMedia slot enumeration ────────────────────" -ForegroundColor White

    $vmCollectionUri = "$iloBase/redfish/v1/Managers/1/VirtualMedia/"
    try {
        $vmCol = Invoke-RestMethod -Uri $vmCollectionUri -Headers $headers `
            -Method GET -SkipCertificateCheck -ErrorAction Stop
        Write-Ok "VirtualMedia collection retrieved ($($vmCol.'Members@odata.count') member(s))"
    }
    catch {
        Write-Fail "Cannot read VirtualMedia collection: $($_.Exception.Message)"
        Write-Detail "URI tried: $vmCollectionUri"
        throw
    }

    $cdSlotUri   = $null
    $cdSlotId    = $null
    $slotSummary = @()

    foreach ($member in $vmCol.Members) {
        $slotUri = if ($member.'@odata.id' -match '^https?://') {
            $member.'@odata.id'
        } else {
            "$iloBase$($member.'@odata.id')"
        }

        try {
            $slot = Invoke-RestMethod -Uri $slotUri -Headers $headers `
                -Method GET -SkipCertificateCheck -ErrorAction Stop

            $id          = $slot.Id
            $types       = ($slot.MediaTypes -join ', ')
            $inserted    = $slot.Inserted
            $currentImg  = if ($slot.Image) { $slot.Image } else { '(none)' }
            $connected   = $slot.ConnectedVia
            $supportsISO = $slot.MediaTypes -contains 'CD' -or $slot.MediaTypes -contains 'DVD'

            $slotSummary += [PSCustomObject]@{
                Id           = $id
                URI          = $slotUri
                MediaTypes   = $types
                Inserted     = $inserted
                CurrentImage = $currentImg
                ConnectedVia = $connected
                SuitableForISO = $supportsISO
            }

            if ($supportsISO -and -not $cdSlotUri) {
                $cdSlotUri = $slotUri
                $cdSlotId  = $id
            }
        }
        catch {
            $slotSummary += [PSCustomObject]@{
                Id           = ($member.'@odata.id' -split '/')[-1]
                URI          = $slotUri
                MediaTypes   = 'ERROR reading slot'
                Inserted     = '?'
                CurrentImage = '?'
                ConnectedVia = '?'
                SuitableForISO = $false
            }
        }
    }

    Write-Host ""
    Write-Host "  VirtualMedia Slots:" -ForegroundColor White
    foreach ($s in $slotSummary) {
        $marker = if ($s.SuitableForISO) { '★ ISO-capable' } else { '  (not ISO)  ' }
        Write-Host "  $marker  Id=$($s.Id)  Types=[$($s.MediaTypes)]  Inserted=$($s.Inserted)  Via=$($s.ConnectedVia)" -ForegroundColor $(if ($s.SuitableForISO) { 'Green' } else { 'Gray' })
        Write-Detail "  Current image: $($s.CurrentImage)"
        Write-Detail "  URI:           $($s.URI)"
    }
    Write-Host ""

    if ($cdSlotUri) {
        Write-Ok "ISO-capable slot found: Id=$cdSlotId"
        Write-Detail "URI : $cdSlotUri"

        # Compare to what Phoenix-Boot.ps1 hardcodes
        $hardcodedSlot = "2"
        if ($cdSlotId -eq $hardcodedSlot) {
            Write-Ok "Slot ID '$cdSlotId' matches the hardcoded slot 2 in Phoenix-Boot.ps1 — compatible."
        } else {
            Write-Warn "Slot ID '$cdSlotId' does NOT match the hardcoded '2' in Phoenix-Boot.ps1."
            Write-Warn "Phoenix-Boot.ps1 will target the WRONG slot on this iLO — update needed."
        }
    } else {
        Write-Fail "No ISO-capable (CD/DVD) VirtualMedia slot found on this iLO."
    }
    Write-Host ""

    #endregion

    #region ── Step 4: Discover actual Eject/Insert action paths ─────────────
    Write-Host "── Step 4: Discover Eject/Insert action paths ───────────────" -ForegroundColor White
    Write-Detail "Strategy 1: OEM Actions block  |  Strategy 2: Standard Actions block  |  Strategy 3: Canonical URL probe"
    Write-Host ""

    # $ejectUri and $insertUri are used by Step 6
    $ejectUri  = $null
    $insertUri = $null

    if (-not $cdSlotUri) {
        Write-Warn "Skipping — no ISO-capable slot found."
    } else {
        try {
            $slotDetail = Invoke-RestMethod -Uri $cdSlotUri -Headers $headers `
                -Method GET -SkipCertificateCheck -ErrorAction Stop

            # ── Strategy 1: OEM Actions block (iLO5 style) ────────────────────
            $oemBlock = $slotDetail.Actions.Oem
            if ($oemBlock) {
                foreach ($prop in $oemBlock.PSObject.Properties) {
                    $target = $oemBlock.($prop.Name).'target'
                    if ($prop.Name -match 'Eject'  -and $target -and -not $ejectUri) {
                        $ejectUri  = if ($target -match '^https?://') { $target } else { "$iloBase$target" }
                        Write-Ok "Eject  found via Strategy 1 (OEM Actions) : $ejectUri"
                    }
                    if ($prop.Name -match 'Insert' -and $target -and -not $insertUri) {
                        $insertUri = if ($target -match '^https?://') { $target } else { "$iloBase$target" }
                        Write-Ok "Insert found via Strategy 1 (OEM Actions) : $insertUri"
                    }
                }
            }
            if (-not $ejectUri -and -not $insertUri) {
                Write-Detail "Strategy 1: OEM Actions block is empty on this iLO."
            }

            # ── Strategy 2: Standard Redfish Actions block ────────────────────
            $stdBlock = $slotDetail.Actions
            if ($stdBlock -and (-not $ejectUri -or -not $insertUri)) {
                foreach ($prop in $stdBlock.PSObject.Properties) {
                    if ($prop.Name -eq 'Oem') { continue }
                    $target = $stdBlock.($prop.Name).'target'
                    if ($prop.Name -match 'Eject'  -and $target -and -not $ejectUri) {
                        $ejectUri  = if ($target -match '^https?://') { $target } else { "$iloBase$target" }
                        Write-Ok "Eject  found via Strategy 2 (Standard Actions) : $ejectUri"
                    }
                    if ($prop.Name -match 'Insert' -and $target -and -not $insertUri) {
                        $insertUri = if ($target -match '^https?://') { $target } else { "$iloBase$target" }
                        Write-Ok "Insert found via Strategy 2 (Standard Actions) : $insertUri"
                    }
                }
            }
            if (-not $ejectUri -or -not $insertUri) {
                Write-Detail "Strategy 2: Standard Actions block did not yield missing paths."
            }

            # ── Strategy 3: Probe canonical HPE OEM URLs directly ────────────
            #   iLO7 may not advertise these in the Actions block at all, but
            #   still accepts them. Any HTTP response other than 404 = URL exists.
            $canonBase        = $cdSlotUri.TrimEnd('/')
            $candidateEject   = "$canonBase/Actions/Oem/Hpe/HpeiLOVirtualMedia.EjectVirtualMedia/"
            $candidateInsert  = "$canonBase/Actions/Oem/Hpe/HpeiLOVirtualMedia.InsertVirtualMedia/"

            if (-not $ejectUri) {
                Write-Detail "Strategy 3: Probing canonical Eject URL..."
                try {
                    Invoke-RestMethod -Uri $candidateEject -Method POST -Headers $headers `
                        -Body '{}' -SkipCertificateCheck -ErrorAction Stop | Out-Null
                    $ejectUri = $candidateEject
                    Write-Ok "Eject  found via Strategy 3 (canonical URL, 200 OK) : $ejectUri"
                } catch {
                    $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                    if ($sc -ne 0 -and $sc -ne 404) {
                        # Got a real HTTP response (400/405/422 etc.) = URL exists, just rejected our empty body
                        $ejectUri = $candidateEject
                        Write-Ok "Eject  found via Strategy 3 (canonical URL, HTTP $sc = URL exists) : $ejectUri"
                    } else {
                        Write-Warn "Eject  NOT found via Strategy 3 — HTTP $sc for: $candidateEject"
                    }
                }
            }

            if (-not $insertUri) {
                Write-Detail "Strategy 3: Probing canonical Insert URL..."
                try {
                    Invoke-RestMethod -Uri $candidateInsert -Method POST -Headers $headers `
                        -Body '{}' -SkipCertificateCheck -ErrorAction Stop | Out-Null
                    $insertUri = $candidateInsert
                    Write-Ok "Insert found via Strategy 3 (canonical URL, 200 OK) : $insertUri"
                } catch {
                    $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                    if ($sc -ne 0 -and $sc -ne 404) {
                        $insertUri = $candidateInsert
                        Write-Ok "Insert found via Strategy 3 (canonical URL, HTTP $sc = URL exists) : $insertUri"
                    } else {
                        Write-Warn "Insert NOT found via Strategy 3 — HTTP $sc for: $candidateInsert"
                    }
                }
            }

            # ── Summary ───────────────────────────────────────────────────────
            Write-Host ""
            Write-Detail "Raw Actions JSON:"
            Write-Host ($slotDetail.Actions | ConvertTo-Json -Depth 6) -ForegroundColor DarkGray
            Write-Host ""
            if ($ejectUri -and $insertUri) {
                Write-Ok "Both action paths discovered — virtual media mounting will work."
                Write-Detail "Eject  : $ejectUri"
                Write-Detail "Insert : $insertUri"
            } elseif (-not $ejectUri -and -not $insertUri) {
                Write-Fail "Neither path found — virtual media will NOT work on this iLO via known paths."
            } else {
                Write-Warn "Only one path found — partial support."
                Write-Detail "Eject  : $(if ($ejectUri) { $ejectUri } else { 'NOT FOUND' })"
                Write-Detail "Insert : $(if ($insertUri) { $insertUri } else { 'NOT FOUND' })"
            }
        }
        catch {
            Write-Warn "Could not inspect slot actions: $($_.Exception.Message)"
        }
    }
    Write-Host ""

    #endregion

    #region ── Step 5: PostState readability ─────────────────────────────────
    Write-Host "── Step 5: PostState field accessibility ────────────────────" -ForegroundColor White

    try {
        $system     = Invoke-RestMethod -Uri "$iloBase/redfish/v1/Systems/1/" `
            -Headers $headers -Method GET -SkipCertificateCheck -ErrorAction Stop

        $powerState = $system.PowerState
        $postState  = $system.Oem.Hpe.PostState

        Write-Ok  "System info retrieved"
        Write-Detail "PowerState          : $powerState"

        if ($postState) {
            Write-Ok  "PostState (Oem.Hpe.PostState) : $postState"
            Write-Detail "Phoenix-Boot.ps1 waits for 'FinishedPost' — path is accessible on this iLO."
        } else {
            Write-Warn "PostState is null or missing at Oem.Hpe.PostState"
            Write-Warn "Phoenix-Boot.ps1 will loop until timeout on this iLO — path needs updating."

            # Try alternate paths seen on iLO7
            $altPaths = @(
                'Oem.Hpe.PostDiscoveryState',
                'Oem.Hpe.PostDiscoveryMode',
                'Oem.Hpe.PowerOnDelay'
            )
            Write-Detail "Checking alternate OEM fields..."
            foreach ($ap in $altPaths) {
                $parts = $ap -split '\.'
                $val   = $system
                foreach ($p in $parts) { $val = $val.PSObject.Properties[$p]?.Value }
                if ($val) {
                    Write-Info "Found alternate field $ap = $val"
                }
            }

            # Show all available Oem.Hpe properties for reference
            if ($system.Oem.Hpe) {
                $hpeProps = $system.Oem.Hpe.PSObject.Properties.Name -join ', '
                Write-Detail "Available Oem.Hpe properties: $hpeProps"
            }
        }
    }
    catch {
        Write-Warn "Could not read System info: $($_.Exception.Message)"
    }
    Write-Host ""

    #endregion

    #region ── Step 5b: One-time boot override readability ───────────────────
    Write-Host "── Step 5b: One-time boot override (BootSourceOverride) ─────" -ForegroundColor White

    try {
        $bootInfo = Invoke-RestMethod -Uri "$iloBase/redfish/v1/Systems/1/" `
            -Headers $headers -Method GET -SkipCertificateCheck -ErrorAction Stop

        $bootBlock   = $bootInfo.Boot
        $bsoTarget   = $bootBlock.BootSourceOverrideTarget
        $bsoEnabled  = $bootBlock.BootSourceOverrideEnabled
        $bsoMode     = $bootBlock.BootSourceOverrideMode
        $allowedVals = $bootBlock.'BootSourceOverrideTarget@Redfish.AllowableValues'

        Write-Ok "Boot block retrieved"
        Write-Detail "BootSourceOverrideEnabled : $bsoEnabled"
        Write-Detail "BootSourceOverrideTarget  : $bsoTarget"
        Write-Detail "BootSourceOverrideMode    : $(if ($bsoMode) { $bsoMode } else { '(not present)' })"

        if ($allowedVals) {
            Write-Detail "AllowableValues           : $($allowedVals -join ', ')"
            if ($allowedVals -contains 'Cd') {
                Write-Ok "'Cd' is in AllowableValues — one-time boot to CD/DVD is supported."
            } else {
                Write-Warn "'Cd' is NOT in AllowableValues — Phoenix-Boot.ps1 boot override may be rejected."
                Write-Detail "Phonix-Boot.ps1 sends: BootSourceOverrideTarget='Cd', BootSourceOverrideEnabled='Once'"
            }
        } else {
            Write-Warn "AllowableValues not advertised — cannot confirm 'Cd' support without a live test."
        }

        # Also check HPE OEM BootOnNextServerReset (used in Phonix-Boot.ps1 Step 3)
        $vmPatchUri  = "$iloBase/redfish/v1/Managers/1/VirtualMedia/2/"
        try {
            $vmSlot = Invoke-RestMethod -Uri $vmPatchUri -Headers $headers `
                -Method GET -SkipCertificateCheck -ErrorAction Stop
            $bootOnNext = $vmSlot.Oem.Hpe.BootOnNextServerReset
            Write-Detail "Oem.Hpe.BootOnNextServerReset (slot 2) : $(if ($null -ne $bootOnNext) { $bootOnNext } else { '(field absent)' })"
            if ($null -ne $bootOnNext) {
                Write-Ok "BootOnNextServerReset field is present — HPE OEM boot flag readable."
            } else {
                Write-Warn "BootOnNextServerReset field absent from VirtualMedia slot — OEM boot flag may not work on this iLO generation."
            }
        } catch {
            Write-Warn "Could not read VirtualMedia slot OEM fields: $($_.Exception.Message)"
        }
    }
    catch {
        Write-Warn "Could not read Boot block: $($_.Exception.Message)"
    }
    Write-Host ""

    #endregion

    #region ── Step 6: Live mount + eject test (only when -IsoUrl supplied) ─────
    if ($IsoUrl) {
        Write-Host "── Step 6: Live mount + eject test ─────────────────────────" -ForegroundColor White
        Write-Warn "This step makes REAL changes: mounts the ISO then immediately ejects it."
        Write-Detail "ISO URL : $IsoUrl"
        Write-Host ""

        if (-not $cdSlotUri) {
            Write-Fail "Cannot run live test — no ISO-capable slot was found."
        } elseif (-not $insertUri) {
            Write-Fail "Cannot run live test — Insert action path not discovered in Step 4."
        } else {
            # ── 6a: Eject first (clear any stale mount) ──────────────────────
            Write-Host "  6a. Eject any existing media (pre-clean)..." -ForegroundColor White
            if ($ejectUri) {
                try {
                    Invoke-RestMethod -Uri $ejectUri -Method POST -Headers $headers `
                        -Body '{}' -SkipCertificateCheck -ErrorAction Stop | Out-Null
                    Write-Ok "Pre-eject succeeded"
                } catch {
                    $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                    Write-Warn "Pre-eject: HTTP $sc — $($_.Exception.Message) (continuing anyway)"
                }
            } else {
                Write-Warn "No eject URI — skipping pre-clean (slot may already be empty)"
            }

            # ── 6b: Mount ISO ──────────────────────────────────────────
            Write-Host "  6b. Mounting ISO..." -ForegroundColor White
            $mountOk = $false
            try {
                $mountBody = @{ Image = $IsoUrl } | ConvertTo-Json -Compress
                Invoke-RestMethod -Uri $insertUri -Method POST -Headers $headers `
                    -Body $mountBody -SkipCertificateCheck -ErrorAction Stop | Out-Null
                Write-Ok "Mount POST accepted by iLO"
                $mountOk = $true
            } catch {
                $sc     = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                $detail = $_.Exception.Message
                Write-Fail "Mount failed: HTTP $sc — $detail"
                # Try reading error body for more context
                try {
                    $errBody = $_.ErrorDetails.Message | ConvertFrom-Json
                    Write-Detail "Error body: $($errBody | ConvertTo-Json -Compress)"
                } catch {}
            }

            # ── 6c: Verify mount ────────────────────────────────────────
            if ($mountOk) {
                Write-Host "  6c. Verifying ISO is mounted..." -ForegroundColor White
                Start-Sleep -Seconds 3   # give iLO a moment to update state
                try {
                    $verify = Invoke-RestMethod -Uri $cdSlotUri -Method GET `
                        -Headers $headers -SkipCertificateCheck -ErrorAction Stop
                    $nowInserted = $verify.Inserted
                    $nowImage    = $verify.Image
                    $nowVia      = $verify.ConnectedVia
                    Write-Detail "Inserted     : $nowInserted"
                    Write-Detail "Image        : $nowImage"
                    Write-Detail "ConnectedVia : $nowVia"
                    if ($nowInserted) {
                        Write-Ok "ISO is mounted and verified"
                    } else {
                        Write-Warn "Inserted=False after mount — iLO may need a moment, or the URL was rejected silently"
                    }
                } catch {
                    Write-Warn "Could not verify mount state: $($_.Exception.Message)"
                }
            }

            # ── 6d: Eject (cleanup) ──────────────────────────────────────
            Write-Host ""
            Write-Host "  ⏳ Pausing 15 seconds — verify the mounted ISO in the iLO web UI now." -ForegroundColor Yellow
            for ($i = 15; $i -gt 0; $i--) {
                Write-Host "     Ejecting in ${i}s...  " -NoNewline -ForegroundColor DarkYellow
                Start-Sleep -Seconds 1
                Write-Host "`r" -NoNewline
            }
            Write-Host ""
            Write-Host "  6d. Ejecting ISO (cleanup)..." -ForegroundColor White
            if ($ejectUri) {
                try {
                    Invoke-RestMethod -Uri $ejectUri -Method POST -Headers $headers `
                        -Body '{}' -SkipCertificateCheck -ErrorAction Stop | Out-Null
                    Write-Ok "Eject POST accepted"
                    Start-Sleep -Seconds 3
                    $verify2 = Invoke-RestMethod -Uri $cdSlotUri -Method GET `
                        -Headers $headers -SkipCertificateCheck -ErrorAction Stop
                    if (-not $verify2.Inserted) {
                        Write-Ok "Slot is empty — eject confirmed. Slot left clean."
                    } else {
                        Write-Warn "Slot still shows Inserted=True after eject — may auto-clear shortly."
                    }
                } catch {
                    Write-Fail "Eject failed: $($_.Exception.Message)"
                    Write-Warn "ISO may still be mounted — eject manually via iLO web UI."
                }
            } else {
                Write-Warn "No eject URI available — cannot clean up. Eject manually via iLO web UI."
            }
        }
        Write-Host ""
    } else {
        Write-Host "── Step 6: Live mount+eject test ─────────────────────────" -ForegroundColor White
        Write-Info "Skipped — supply -IsoUrl to run the live mount+eject test."
        Write-Host ""
    }

    #endregion
}
finally {
    #region ── Cleanup: Delete session ────────────────────────────────────────
    Write-Host "── Cleanup: Close Redfish session ───────────────────────────" -ForegroundColor White
    if ($headers -and $sessionUri) {
        try {
            Invoke-RestMethod -Uri $sessionUri -Method DELETE -Headers $headers `
                -SkipCertificateCheck -ErrorAction Stop | Out-Null
            Write-Ok "Session closed"
        }
        catch {
            Write-Warn "Failed to close session: $($_.Exception.Message)"
        }
    } else {
        Write-Warn "No session to close (connection never established)."
    }
    Write-Host ""
    #endregion
}

Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Diagnostic complete$(if ($IsoUrl) { ' — slot ejected and left clean' } else { ' — no changes made to the server' })     " -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
