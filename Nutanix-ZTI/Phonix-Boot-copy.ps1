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
    Path to the cluster JSON config file (e.g. Configs\DKCDC-1P-NTXTEST-01.json).

.PARAMETER IloHost
    Optional filter — process only the node whose iLO_ip matches this value.

.PARAMETER IsoUrl
    Optional override for the phoenix_iso_url in the config file.
    Accepts either a remote HTTP(S) URL or a local file path
    (e.g. E:\Software\Nutanix-package\EMEA-Phoenix-5.10.3-x86_64.iso).
    When a local path is provided the script automatically starts an HTTP
    listener on port 8888 and builds an http://<localIP>:8888/<filename>
    URL that iLO can reach over the LAN. The listener is stopped once all
    nodes have finished booting.

.PARAMETER PostStateTimeoutMinutes
    Maximum minutes to wait per node for PostState=FinishedPost before giving up
    and moving to the next node. After FinishedPost is confirmed a fixed 5-minute
    buffer is applied so Phoenix can copy squashfs.img from the ISO into RAM and
    complete rc.local / service init. The ISO is intentionally NOT ejected —
    Phoenix reads images from it throughout the process.
    Default: 35.

.EXAMPLE
    .\Phonix-Boot.ps1 -ConfigFile .\Configs\DKCDC-1P-NTXTEST-01.json
    Processes all nodes in the cluster config.

.EXAMPLE
    .\Phonix-Boot.ps1 -ConfigFile .\Configs\DKCDC-1P-NTXTEST-01.json -IloHost "10.10.16.120"
    Processes only the node with that iLO IP.

.EXAMPLE
    .\Phonix-Boot.ps1 -ConfigFile .\Configs\DKCDC-1P-NTXTEST-01.json -IsoUrl "https://example.com/phoenix.iso" -PostStateTimeoutMinutes 60
    Override ISO URL and wait up to 60 min per node for FinishedPost.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [string]$IloHost,
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
        if ($_.ErrorDetails.Message) {
            Write-Host "         iLO detail: $($_.ErrorDetails.Message)" -ForegroundColor Red
        }
        throw
    }
}

#endregion

#region --- Main ---

# --- Load cluster config ---
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

# ---------------------------------------------------------------------------
# Local ISO path support — auto-start an HTTPS listener so iLO can fetch it
# iLO 7 firmware 1.14+ rejects plain HTTP for Virtual Media; HTTPS is required.
# ---------------------------------------------------------------------------
$httpServerJob      = $null
$httpCertThumbprint = $null
if (Test-Path $resolvedIsoUrl -PathType Leaf -ErrorAction SilentlyContinue) {
    $isoFile  = Get-Item -Path $resolvedIsoUrl
    $isoDir   = $isoFile.DirectoryName
    $isoName  = $isoFile.Name
    $httpPort = 8888

    # Pick the best local IPv4 that iLO can reach (first non-loopback, non-APIPA)
    $localIPs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
        Sort-Object PrefixLength)
    if ($localIPs.Count -eq 0) {
        Write-Host "ERROR: Cannot determine a local IPv4 address for the HTTPS server." -ForegroundColor Red
        exit 1
    }
    $localIP = $localIPs[0].IPAddress

    Write-Host "Local ISO path detected — starting HTTPS server on $localIP`:$httpPort..." -ForegroundColor Cyan
    Write-Host "  File : $($isoFile.FullName)  ($([math]::Round($isoFile.Length / 1MB, 1)) MB)"

    # Add a temporary firewall rule (best-effort, requires admin)
    try {
        if (-not (Get-NetFirewallRule -DisplayName "Phoenix ISO HTTPS $httpPort" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "Phoenix ISO HTTPS $httpPort" `
                -Direction Inbound -Protocol TCP -LocalPort $httpPort -Action Allow `
                -ErrorAction Stop | Out-Null
            Write-Host "  [OK] Firewall rule created for port $httpPort" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [WARN] Could not create firewall rule (run as Administrator if iLO can't connect): $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Generate self-signed cert and bind to port so HttpListener can serve HTTPS.
    # Must run before Start-Job. Requires Administrator.
    try {
        $isoCert = New-SelfSignedCertificate `
            -Subject "CN=PhoenixIsoServer" `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -NotAfter (Get-Date).AddDays(1) `
            -KeyUsage DigitalSignature, KeyEncipherment `
            -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.1") `
            -ErrorAction Stop
        $httpCertThumbprint = $isoCert.Thumbprint
        $sslAppId  = "{$([System.Guid]::NewGuid().ToString())}"
        $sslOut    = netsh http add sslcert ipport=0.0.0.0:$httpPort certhash=$httpCertThumbprint appid=$sslAppId 2>&1
        if ($LASTEXITCODE -ne 0) { throw "netsh: $sslOut" }
        Write-Host "  [OK] Self-signed cert bound to port $httpPort (thumbprint: $($httpCertThumbprint.Substring(0,8))...)" -ForegroundColor Green
    } catch {
        Write-Host "  [WARN] HTTPS cert setup failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "         Run as Administrator. iLO 7 requires HTTPS — mount will fail without it." -ForegroundColor Yellow
    }

    # Run the HTTPS listener as a PowerShell background job
    $httpServerJob = Start-Job -ScriptBlock {
        param([string]$dir, [int]$port)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("https://+:$port/")
        $listener.Start()
        while ($listener.IsListening) {
            try {
                $ctx      = $listener.GetContext()
                $req      = $ctx.Request
                $res      = $ctx.Response
                $rawUrl   = $req.Url.LocalPath.TrimStart('/')
                $filePath = Join-Path $dir $rawUrl
                if ([System.IO.File]::Exists($filePath)) {
                    $res.ContentType     = 'application/octet-stream'
                    $res.ContentLength64 = (Get-Item $filePath).Length
                    if ($req.HttpMethod -eq 'HEAD') {
                        $res.Close()
                    } else {
                        $fs  = [System.IO.File]::OpenRead($filePath)
                        $buf = [byte[]]::new(262144)   # 256 KB chunks
                        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                            $res.OutputStream.Write($buf, 0, $n)
                        }
                        $fs.Close()
                        $res.Close()
                    }
                } else {
                    $res.StatusCode = 404
                    $res.Close()
                }
            } catch { <# connection-reset during large transfers is normal #> }
        }
    } -ArgumentList $isoDir, $httpPort

    Start-Sleep -Seconds 2   # give listener time to bind

    $scheme         = if ($httpCertThumbprint) { 'https' } else { 'http' }
    $resolvedIsoUrl = "$scheme`://$localIP`:$httpPort/$isoName"
    Write-Host "  URL  : $resolvedIsoUrl" -ForegroundColor Green
    Write-Host ""
}
# ---------------------------------------------------------------------------

# Build server list from config nodes
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

Write-Host ""
Write-Host "=== Phoenix Boot — Mount ISO & One-Time Boot ===" -ForegroundColor Cyan
Write-Host "Config  : $ConfigFile"
Write-Host "ISO URL : $resolvedIsoUrl"
Write-Host "Nodes   : $($servers.Count) ($($servers.iloHost -join ', '))"
Write-Host ""

Write-Host "Running Phoenix boot on $($servers.Count) node(s) in parallel..." -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Export ISO server cert so it can be imported into each iLO's trust store.
# iLO 7 validates the HTTPS server certificate when mounting remote Virtual Media.
# Start-IsoHttpServer.ps1 installs a self-signed cert as CN=IsoServer in
# Cert:\LocalMachine\My — we export it here and push it to iLO via Redfish.
# ---------------------------------------------------------------------------
$isoCertPem = $null
if ($resolvedIsoUrl -match '^https://') {
    $isoCert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -match 'CN=IsoServer|CN=PhoenixIsoServer' } |
        Sort-Object NotBefore -Descending |
        Select-Object -First 1
    if ($isoCert) {
        $isoCertPem = "-----BEGIN CERTIFICATE-----`n" +
            [Convert]::ToBase64String($isoCert.RawData, 'InsertLineBreaks') +
            "`n-----END CERTIFICATE-----"
        Write-Host "ISO server cert found (thumbprint: $($isoCert.Thumbprint.Substring(0,8))...) — will import into each iLO trust store" -ForegroundColor DarkGray
    } else {
        Write-Host "WARN: No IsoServer cert in Cert:\LocalMachine\My" -ForegroundColor Yellow
        Write-Host "      Run Start-IsoHttpServer.ps1 as Administrator first, then re-run this script." -ForegroundColor Yellow
    }
}
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
            if ($_.ErrorDetails.Message) {
                Write-Host "         iLO detail: $($_.ErrorDetails.Message)" -ForegroundColor Red
            }
            throw
        }
    }

    $server                  = $_
    $resolvedIsoUrl          = $using:resolvedIsoUrl
    $PostStateTimeoutMinutes = $using:PostStateTimeoutMinutes
    $isoCertPem              = $using:isoCertPem
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
                -TimeoutSec 15 -SkipCertificateCheck -ErrorAction Stop
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

        # If the ISO is served over HTTPS, import its self-signed certificate into iLO's
        # trusted store so iLO 7 can validate the connection (iLO 7 rejects untrusted certs).
        if ($resolvedIsoUrl -match '^https://' -and $isoCertPem) {
            $certBody = @{ Certificate = $isoCertPem; CertificateType = 'PEM' }
            # Try the standard iLO 7 path first, then fall back to iLO 5 path (both IgnoreError)
            Invoke-IloApi -Uri "$iloBase/redfish/v1/Managers/1/SecurityService/TrustedCertificates/" `
                -Headers $headers -Method POST -Body $certBody `
                -StepName "$tag Import ISO server cert into iLO trust store" -IgnoreError | Out-Null
        }
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
        Invoke-IloApi -Uri $ejectUri -Headers $headers -Method POST `
            -StepName "$tag Eject existing virtual media" -IgnoreError | Out-Null

        # Step 2: Mount ISO
        # iLO 7 standard Redfish InsertMedia requires TransferProtocolType.
        # UserName/Password are empty strings (anonymous). VerifyCertificate=false
        # tells iLO 7 not to validate the SSL cert of the HTTPS server — required
        # when serving from a self-signed cert (e.g. Start-IsoHttpServer.ps1).
        $insertBody = @{
            Image                = $resolvedIsoUrl
            Inserted             = $true
            WriteProtected       = $true
            TransferProtocolType = if ($resolvedIsoUrl -match '^https://') { 'HTTPS' } else { 'HTTP' }
            UserName             = ''
            Password             = ''
            VerifyCertificate    = $false
        }
        Invoke-IloApi -Uri $insertUri -Headers $headers -Method POST -Body $insertBody `
            -StepName "$tag Mount ISO image" | Out-Null

        # Verify the mount actually took effect before rebooting
        Start-Sleep -Seconds 3
        try {
            $slotCheck = Invoke-RestMethod -Uri "$iloBase/redfish/v1/Managers/1/VirtualMedia/2/" `
                -Headers $headers -Method GET -SkipCertificateCheck -ErrorAction Stop
            $insertedOK = $slotCheck.Inserted -eq $true
            $mountedUrl = $slotCheck.Image
            if ($insertedOK) {
                Write-Host "$tag [OK] ISO confirmed mounted: $mountedUrl" -ForegroundColor Green
            } else {
                Write-Host "$tag [WARN] VirtualMedia slot reports Inserted=false after InsertMedia." -ForegroundColor Yellow
                Write-Host "$tag        iLO may not be able to reach the ISO server — check URL and network." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "$tag [WARN] Could not verify mount state: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # Step 3: Set BootOnNextServerReset (HPE OEM flag)
        $vmPatchUri = "$iloBase/redfish/v1/Managers/1/VirtualMedia/2/"
        Invoke-IloApi -Uri $vmPatchUri -Headers $headers -Method PATCH `
            -Body @{ Oem = @{ Hpe = @{ BootOnNextServerReset = $true } } } `
            -StepName "$tag Set BootOnNextServerReset (OEM)" | Out-Null

        # Step 4: Set one-time boot override to Cd (standard Redfish)
        # BootSourceOverrideMode:UEFI is required on UEFI systems — without it
        # the override is interpreted as legacy BIOS and silently ignored.
        $systemUri = "$iloBase/redfish/v1/Systems/1/"
        Invoke-IloApi -Uri $systemUri -Headers $headers -Method PATCH `
            -Body @{ Boot = @{ BootSourceOverrideTarget = 'Cd'; BootSourceOverrideEnabled = 'Once'; BootSourceOverrideMode = 'UEFI' } } `
            -StepName "$tag Set one-time boot to Cd (UEFI)" | Out-Null

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

# Stop the background HTTPS server if we started one
if ($httpServerJob) {
    Stop-Job   -Job $httpServerJob
    Remove-Job -Job $httpServerJob
    Write-Host "HTTPS server stopped." -ForegroundColor DarkGray
    # Remove SSL cert binding and the temporary certificate
    if ($httpCertThumbprint) {
        try {
            netsh http delete sslcert ipport=0.0.0.0:8888 | Out-Null
            Remove-Item -Path "Cert:\LocalMachine\My\$httpCertThumbprint" -Force -ErrorAction SilentlyContinue
        } catch {}
    }
    # Remove the firewall rule we added
    try {
        Remove-NetFirewallRule -DisplayName "Phoenix ISO HTTPS 8888" -ErrorAction SilentlyContinue
    } catch {}
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
