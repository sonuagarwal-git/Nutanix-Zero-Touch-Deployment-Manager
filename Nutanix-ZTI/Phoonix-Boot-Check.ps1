<#
.SYNOPSIS
    Checks whether cluster nodes have booted into Phoenix/Discovery OS via iLO Redfish.
.DESCRIPTION
    Supports HPE iLO 5 and iLO 7. Detects the iLO generation automatically after login
    and logs it in the output. Polls Oem.Hpe.PostState and PowerState to confirm Phoenix
    OS is running — these fields work identically on both iLO generations.
    Reads iLO credentials from the cluster config file under 'network.nodes[]'
    (fields: iLO_ip, iLO_username, iLO_password).
.PARAMETER ConfigFile
    Path to the cluster JSON config file (e.g. Configs\DKCDC-1P-NTXTEST-01.json).
.PARAMETER IloHost
    Optional filter — check only the node whose iLO_ip matches this value.
.PARAMETER TimeoutMinutes
    Max wait time per node. 0 = single check without polling. Default: 15.
.PARAMETER PollIntervalSeconds
    Poll interval when TimeoutMinutes > 0. Default: 20.
.EXAMPLE
    .\Phoonix-Boot-Check.ps1 -ConfigFile .\Configs\DKCDC-1P-NTXTEST-01.json
.EXAMPLE
    .\Phoonix-Boot-Check.ps1 -ConfigFile .\Configs\DKCDC-1P-NTXTEST-01.json -IloHost 10.10.16.120
.EXAMPLE
    .\Phoonix-Boot-Check.ps1 -ConfigFile .\Configs\DKCDC-1P-NTXTEST-01.json -TimeoutMinutes 10
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [string]$IloHost,
    [int]$TimeoutMinutes = 15,
    [int]$PollIntervalSeconds = 20
)

$ErrorActionPreference = 'Stop'

# ── Load cluster config ───────────────────────────────────────────────────────
if (-not (Test-Path $ConfigFile)) {
    Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
    exit 1
}

try {
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
} catch {
    Write-Host "ERROR: Failed to parse config file: $_" -ForegroundColor Red
    exit 1
}

if (-not $config.network -or -not $config.network.nodes -or $config.network.nodes.Count -eq 0) {
    Write-Host "ERROR: No nodes defined in config under 'network.nodes'." -ForegroundColor Red
    exit 1
}

$servers = $config.network.nodes | ForEach-Object {
    if (-not $_.iLO_ip -or -not $_.iLO_username -or -not $_.iLO_password) {
        Write-Host "WARN: Node '$($_.hostname)' is missing iLO_ip/iLO_username/iLO_password — skipping." -ForegroundColor Yellow
        return
    }
    [PSCustomObject]@{
        iloHost  = $_.iLO_ip
        username = $_.iLO_username
        password = $_.iLO_password
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

# ── Helper: Create iLO session ───────────────────────────────────────────────
function New-IloSession {
    param([string]$IloBase, [string]$User, [string]$Token)
    $body = @{ UserName = $User; Password = $Token } | ConvertTo-Json -Compress
    $resp = Invoke-WebRequest -Uri "$IloBase/redfish/v1/SessionService/Sessions/" `
        -Method POST -Body $body -ContentType 'application/json' -SkipCertificateCheck -ErrorAction Stop
    $xAuth = $resp.Headers['X-Auth-Token'] | Select-Object -First 1
    $loc   = $resp.Headers['Location'] | Select-Object -First 1
    if ($loc -and $loc -notmatch '^https?://') { $loc = "$IloBase$loc" }
    return @{
        Headers    = @{ 'X-Auth-Token' = $xAuth; 'Content-Type' = 'application/json' }
        SessionUri = $loc
    }
}

# ── Check each server ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Test Phoenix/Discovery OS Boot Status ===" -ForegroundColor Cyan
Write-Host "Config : $ConfigFile"
Write-Host "Nodes  : $($servers.Count) ($($servers.iloHost -join ', '))"
Write-Host "Mode   : $(if ($TimeoutMinutes -gt 0) { "Poll (timeout: ${TimeoutMinutes}min)" } else { 'Single check' })"
Write-Host ""

$results = @()

foreach ($srv in $servers) {
    $iloBase = "https://$($srv.iloHost)"
    $display = if ($srv.hostname) { "$($srv.hostname) [$($srv.iloHost)]" } else { $srv.iloHost }
    $systemUri = "$iloBase/redfish/v1/Systems/1/"

    Write-Host "--- $display ---" -ForegroundColor Cyan

    $session = $null
    try {
        $session = New-IloSession -IloBase $iloBase -User $srv.username -Token $srv.password
        $headers = $session.Headers

        # Detect iLO generation — informational only, PostState path is the same on iLO 5 and iLO 7
        $iloGenNum  = 0
        $iloVerStr  = 'unknown'
        try {
            $mgr = Invoke-RestMethod -Uri "$iloBase/redfish/v1/Managers/1/" `
                -Headers $headers -Method GET -SkipCertificateCheck -ErrorAction Stop
            if     ($mgr.Model          -match 'iLO\s*(\d+)') { $iloGenNum = [int]$Matches[1] }
            elseif ($mgr.FirmwareVersion -match '^iLO\s*(\d+)') { $iloGenNum = [int]$Matches[1] }
            $iloVerStr = "iLO $iloGenNum ($($mgr.FirmwareVersion))"
            Write-Host "  [OK] Connected — $iloVerStr" -ForegroundColor Green
        } catch {
            Write-Host "  [WARN] Could not read iLO version: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        $startTime = Get-Date
        $deadline  = $startTime.AddMinutes($TimeoutMinutes)
        $confirmed = $false

        do {
            $elapsed    = [int]((Get-Date) - $startTime).TotalSeconds
            $elapsedStr = "$([int]($elapsed/60))m $($elapsed%60)s"

            try {
                $system = Invoke-RestMethod -Uri $systemUri -Headers $headers -Method GET `
                    -SkipCertificateCheck -ErrorAction Stop

                $powerState = $system.PowerState
                $postState  = $system.Oem.Hpe.PostState
                $model      = $system.Model
                $serial     = $system.SerialNumber

                if ($postState -eq 'FinishedPost' -and $powerState -eq 'On') {
                    $osInfo = ""
                    if ($system.Oem.Hpe.PostMode) { $osInfo = $system.Oem.Hpe.PostMode }

                    Write-Host "  [$elapsedStr] PostState=FinishedPost, PowerState=On" -ForegroundColor Green
                    Write-Host "  [OK] OS is running — Phoenix/Discovery OS confirmed" -ForegroundColor Green
                    Write-Host "        iLO:    $iloVerStr" -ForegroundColor Gray
                    Write-Host "        Model:  $model" -ForegroundColor Gray
                    Write-Host "        Serial: $serial" -ForegroundColor Gray
                    $confirmed = $true
                    $results += [PSCustomObject]@{
                        iLO = $display; Serial = $serial; Model = $model; iLOVersion = $iloVerStr
                        PostState = $postState; PowerState = $powerState; Status = 'PHOENIX_RUNNING'
                    }
                }
                elseif ($postState -eq 'InPostDiscoveryComplete') {
                    Write-Host "  [$elapsedStr] POST discovery complete, OS loading..." -ForegroundColor Yellow
                }
                elseif ($postState -match 'InPost') {
                    Write-Host "  [$elapsedStr] Server is in POST ($postState)..." -ForegroundColor DarkGray
                }
                elseif ($powerState -eq 'Off') {
                    Write-Host "  [$elapsedStr] Server is POWERED OFF" -ForegroundColor Red
                    if ($TimeoutMinutes -eq 0) {
                        $results += [PSCustomObject]@{
                            iLO = $display; Serial = $serial; Model = $model
                            PostState = $postState; PowerState = $powerState; Status = 'POWERED_OFF'
                        }
                        $confirmed = $true
                    }
                }
                else {
                    Write-Host "  [$elapsedStr] PowerState=$powerState, PostState=$postState" -ForegroundColor DarkGray
                }
            }
            catch {
                Write-Host "  [$elapsedStr] iLO query failed: $($_.Exception.Message)" -ForegroundColor Yellow
                try {
                    $session = New-IloSession -IloBase $iloBase -User $srv.username -Token $srv.password
                    $headers = $session.Headers
                } catch {}
            }

            if (-not $confirmed -and $TimeoutMinutes -gt 0 -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds $PollIntervalSeconds
            }
        } while (-not $confirmed -and $TimeoutMinutes -gt 0 -and (Get-Date) -lt $deadline)

        if (-not $confirmed) {
            Write-Host "  [TIMEOUT] Node did not reach FinishedPost within ${TimeoutMinutes} minutes" -ForegroundColor Red
            $results += [PSCustomObject]@{
                iLO = $display; Serial = ''; Model = ''; iLOVersion = $iloVerStr
                PostState = 'Unknown'; PowerState = 'Unknown'; Status = 'NOT_READY'
            }
        }
    }
    catch {
        Write-Host "  [FAIL] Could not connect to iLO: $($_.Exception.Message)" -ForegroundColor Red
        $results += [PSCustomObject]@{
            iLO = $display; Serial = ''; Model = ''; iLOVersion = 'unknown'
            PostState = 'N/A'; PowerState = 'N/A'; Status = 'ILO_UNREACHABLE'
        }
    }
    finally {
        if ($session -and $session.SessionUri) {
            try {
                Invoke-RestMethod -Uri $session.SessionUri -Method DELETE -Headers $session.Headers `
                    -SkipCertificateCheck -ErrorAction SilentlyContinue | Out-Null
            } catch {}
        }
    }
    Write-Host ""
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host ("{0,-40} {1,-12} {2,-10} {3,-22} {4}" -f 'Node', 'PostState', 'Power', 'iLO Version', 'Status') -ForegroundColor White
Write-Host ('-' * 100) -ForegroundColor DarkGray
foreach ($r in $results) {
    $color = switch ($r.Status) {
        'PHOENIX_RUNNING' { 'Green'  }
        'POWERED_OFF'     { 'Red'    }
        'ILO_UNREACHABLE' { 'Red'    }
        default           { 'Yellow' }
    }
    Write-Host ("{0,-40} {1,-12} {2,-10} {3,-22} {4}" -f $r.iLO, $r.PostState, $r.PowerState, $r.iLOVersion, $r.Status) -ForegroundColor $color
}
Write-Host ''
$ready = @($results | Where-Object { $_.Status -eq 'PHOENIX_RUNNING' }).Count
Write-Host "Phoenix ready: $ready / $($results.Count)" -ForegroundColor $(if ($ready -eq $results.Count) { 'Green' } else { 'Yellow' })

if ($ready -eq $results.Count -and $results.Count -gt 0) {
    exit 0
} else {
    Write-Host "ERROR: Not all nodes confirmed in Phoenix OS ($ready / $($results.Count) ready)." -ForegroundColor Red
    exit 1
}
