#Requires -Version 7.0
<#
.SYNOPSIS
    Image Nutanix nodes via Foundation Central — preparation only (no cluster formation)
.DESCRIPTION
    Images nodes via Foundation Central with skip_cluster_formation = true.
    Used to prepare nodes in a clean imaged state before testing Deploy-Cluster.ps1.
    Always performs forced re-imaging (nodes will be wiped).
    Does NOT form a cluster. Use Deploy-Cluster.ps1 for full deployment.
.PARAMETER ConfigFile
    Path to the imaging configuration JSON file. Default: Configs\DKLAB-3-ImageOnly.json
.PARAMETER DryRun
    Run validation only without making any changes
.PARAMETER SkipPasswordCheck
    Skip the password security validation
.PARAMETER Force
    Skip confirmation prompts
.NOTES
    Mode is hardcoded:
    - Re-imaging is ALWAYS forced via Foundation Central (nodes will be wiped)
    - Mode is always 'ImageOnly': image nodes only, no cluster formation
.EXAMPLE
    .\Deploy-Cluster-TestImaging.ps1 -DryRun
    Run validation without imaging
.EXAMPLE
    .\Deploy-Cluster-TestImaging.ps1 -ConfigFile .\Configs\DKLAB-3-ImageOnly.json
    Image nodes via FC (no cluster formation)
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigFile = "Configs\DKLAB-3-ImageOnly.json",

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$SkipPasswordCheck,

    [Parameter()]
    [switch]$Force
)

# ── Fixed operational constants ───────────────────────────────────────────────
# Re-imaging is always forced — nodes are wiped and imaged by Foundation Central
# Mode is always ImageOnly: image nodes, do NOT form cluster
$Mode         = 'ImageOnly'

# ── Deployment Configuration ─────────────────────────────────────────────────
$MaxLogFiles   = 5                               # Maximum log files to keep per type
$LogsDirectory = Join-Path $PSScriptRoot 'Logs'  # Single log directory for all output
# ─────────────────────────────────────────────────────────────────────────────

# Ignorerer SSL-certifikatvalidering for alle HTTPS-forespørgsler (kun til test/ikke-produktionsbrug)
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
$PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true

$ErrorActionPreference = "Stop"

# ══════════════════════════════════════════════════════════════════════════════
# Inline module functions (self-contained — no external modules required)
# ══════════════════════════════════════════════════════════════════════════════

# Module-level variables
$script:DeploymentLogFile  = $null
$script:MaxLogFiles        = 5

#region Logging Functions

function Write-DeploymentLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")] [string]$Level = "INFO",
        [string]$LogFile = $script:DeploymentLogFile
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    $outputLevel = if ($env:ZTIPS_OUTPUT_LEVEL) { $env:ZTIPS_OUTPUT_LEVEL } else { 'verbose' }
    $show = switch ($outputLevel) {
        'minimal' { $Level -in @('WARN','ERROR') }
        'normal'  { $Level -in @('INFO','SUCCESS','WARN','ERROR') }
        default   { $Level -ne 'DEBUG' }
    }
    if ($show) {
        switch ($Level) {
            "INFO"    { Write-Host $logMessage }
            "WARN"    { Write-Host $logMessage -ForegroundColor Yellow }
            "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
            "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        }
    }
    if ($Level -eq 'DEBUG') { Write-Verbose $logMessage }
    if ($LogFile) { Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue }
}

function Invoke-LogRotation {
    param(
        [string]$Directory,
        [string]$Pattern,
        [int]$MaxFiles = $script:MaxLogFiles
    )
    try {
        $files = Get-ChildItem -Path $Directory -Filter $Pattern -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending
        if ($files.Count -gt $MaxFiles) {
            $files | Select-Object -Skip $MaxFiles | ForEach-Object {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                Write-DeploymentLog -Message "Log rotation: removed old file $($_.Name)" -Level DEBUG
            }
        }
    } catch {}
}

function Initialize-DeploymentLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$ClusterName,
        [string]$LogDirectory = ".\Logs",
        [int]$MaxLogFiles = 5
    )
    $script:LogsDirectory = $LogDirectory
    $script:MaxLogFiles   = $MaxLogFiles
    if (-not (Test-Path $LogDirectory)) { New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null }
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $script:DeploymentLogFile = Join-Path $LogDirectory "deployment-log-$ClusterName-$timestamp.txt"
    $header = @"
═══════════════════════════════════════════════════════════════
Nutanix Cluster Deployment Log
═══════════════════════════════════════════════════════════════

Deployment Information:
  Cluster Name:     $ClusterName
  Started:          $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Script Version:   1.0

═══════════════════════════════════════════════════════════════

"@
    Set-Content -Path $script:DeploymentLogFile -Value $header
    Invoke-LogRotation -Directory $LogDirectory -Pattern "deployment-log-*.txt" -MaxFiles $MaxLogFiles
    return $script:DeploymentLogFile
}

#endregion

#region IP Address Functions

function Test-IPAddressFormat {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$IPAddress)
    $ipRegex = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
    return $IPAddress -match $ipRegex
}

function Test-IPPrefixFormat {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$IPPrefix)
    $prefixRegex = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){2}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
    return $IPPrefix -match $prefixRegex
}

function Test-IPInUse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$IPAddress,
        [int]$TimeoutMilliseconds = 1000
    )
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $result = $ping.Send($IPAddress, $TimeoutMilliseconds)
        return $result.Status -eq 'Success'
    } catch { return $false }
}

function Get-IPAddresses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [string]$IPPrefix,
        [Parameter(Mandatory = $true)]  [string]$GatewayLastOctet,
        [Parameter(Mandatory = $false)] [string]$ClusterVIP,
        [Parameter(Mandatory = $false)] [PSCustomObject]$Nodes,
        [Parameter(Mandatory = $false)] [string[]]$IPMIIPs = @()
    )
    $clusterVipAddress = if ($ClusterVIP) { $ClusterVIP } else { "${IPPrefix}.10" }
    $node1Hypervisor = "${IPPrefix}.12"; $node1CVM = "${IPPrefix}.11"
    $node2Hypervisor = "${IPPrefix}.14"; $node2CVM = "${IPPrefix}.13"
    if ($Nodes -and $Nodes.Count -ge 1) {
        if ($Nodes[0].hypervisor_ip) { $node1Hypervisor = $Nodes[0].hypervisor_ip }
        if ($Nodes[0].cvm_ip) { $node1CVM = $Nodes[0].cvm_ip }
        if ($Nodes.Count -ge 2) {
            if ($Nodes[1].hypervisor_ip) { $node2Hypervisor = $Nodes[1].hypervisor_ip }
            if ($Nodes[1].cvm_ip) { $node2CVM = $Nodes[1].cvm_ip }
        }
    }
    $ipAddresses = @{
        ClusterVIP       = $clusterVipAddress
        Node1_CVM        = $node1CVM;    Node1_Hypervisor = $node1Hypervisor
        Node2_CVM        = $node2CVM;    Node2_Hypervisor = $node2Hypervisor
        Gateway          = "${IPPrefix}.${GatewayLastOctet}"
        Subnet           = "${IPPrefix}.0/24"
    }
    if ($IPMIIPs -and $IPMIIPs.Count -ge 2) {
        $ipAddresses['Node1_IPMI'] = $IPMIIPs[0]; $ipAddresses['Node2_IPMI'] = $IPMIIPs[1]
    } else {
        $ipAddresses['Node1_IPMI'] = "${IPPrefix}.21"; $ipAddresses['Node2_IPMI'] = "${IPPrefix}.22"
    }
    return $ipAddresses
}

#endregion

#region Connection Functions

function Test-FCEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$BaseUrl,
        [Parameter(Mandatory = $true)] [hashtable]$Headers
    )
    $endpointsToTry = @(
        @{Path = "/api/fc/v1/imaged_nodes/list"; Description = "FC v1 API - imaged nodes list"; Method = "GET"},
        @{Path = "/api/fc/v1/imaged_nodes/list"; Description = "FC v1 API - imaged nodes list (POST)"; Method = "POST"},
        @{Path = "/api/fc/v1/imaged_nodes"; Description = "FC v1 API - imaged nodes"; Method = "GET"},
        @{Path = "/dm/foundation_central/api/imaged_nodes/list"; Description = "FC via DM path - imaged nodes (GET)"; Method = "GET"},
        @{Path = "/api/foundation_central/v3/imaged_nodes/list"; Description = "Standard v3 API with /api prefix"; Method = "POST"},
        @{Path = "/foundation_central/v3/imaged_nodes/list"; Description = "v3 API without /api prefix"; Method = "POST"},
        @{Path = "/api/nutanix/v3/clusters/list"; Description = "Prism Central v3 API (might be PC not FC)"; Method = "POST"}
    )
    foreach ($endpoint in $endpointsToTry) {
        $testUrl = "$BaseUrl$($endpoint.Path)"
        Write-DeploymentLog -Message "Testing: $testUrl ($($endpoint.Method))" -Level DEBUG
        try {
            $params = @{ Uri = $testUrl; Method = $endpoint.Method; Headers = $Headers; TimeoutSec = 10; ErrorAction = 'Stop' }
            if ($endpoint.Method -eq "POST") {
                $testBody = @{kind = "imaged_node"; length = 1} | ConvertTo-Json
                $params['Body'] = $testBody; $params['ContentType'] = 'application/json'
            }
            $testResponse = Invoke-RestMethod @params
            if ($testResponse -is [string] -and $testResponse -match '<!doctype html>') { continue }
            Write-DeploymentLog -Message "SUCCESS: $($endpoint.Description)" -Level SUCCESS
            return @{ Path = $endpoint.Path; Method = $endpoint.Method; BasePath = ($endpoint.Path -replace '/imaged_nodes/list|/aos_packages/list|/clusters/list|/cluster', '') }
        } catch {
            Write-DeploymentLog -Message "Failed: $($endpoint.Description) - $($_.Exception.Message)" -Level DEBUG
        }
    }
    return $null
}

function Test-ImagingEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$BaseUrl,
        [Parameter(Mandatory = $true)] [hashtable]$Headers
    )
    $imagingEndpoints = @(
        @{Path = "/api/fc/v1/imaged_clusters"; Description = "FC v1 API - imaged clusters"; Method = "POST"},
        @{Path = "/api/fc/v1/cluster"; Description = "FC v1 API - cluster"; Method = "POST"},
        @{Path = "/api/foundation_central/v3/imaged_clusters"; Description = "FC v3 API - imaged clusters"; Method = "POST"},
        @{Path = "/api/foundation_central/imaged_clusters"; Description = "FC API (no version) - imaged clusters"; Method = "POST"},
        @{Path = "/foundation_central/v3/imaged_clusters"; Description = "FC v3 API (no /api) - imaged clusters"; Method = "POST"}
    )
    Write-DeploymentLog -Message "Testing imaging endpoints..." -Level INFO
    foreach ($endpoint in $imagingEndpoints) {
        $testUrl = "$BaseUrl$($endpoint.Path)"
        Write-DeploymentLog -Message "Testing imaging: $testUrl" -Level DEBUG
        try {
            $testBody = @{spec = @{cluster_name = "test"}} | ConvertTo-Json
            $params = @{ Uri = $testUrl; Method = $endpoint.Method; Headers = $Headers; Body = $testBody; ContentType = 'application/json'; TimeoutSec = 10; ErrorAction = 'Stop' }
            $null = Invoke-RestMethod @params
            Write-DeploymentLog -Message "SUCCESS: $($endpoint.Description) endpoint exists" -Level SUCCESS
            return @{ Path = $endpoint.Path; Method = $endpoint.Method }
        } catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -match "404|not found") { continue }
            if ($errorMessage -match "400|validation|required|Details of nodes") {
                Write-DeploymentLog -Message "SUCCESS: $($endpoint.Description) endpoint exists (validation error is expected)" -Level SUCCESS
                return @{ Path = $endpoint.Path; Method = $endpoint.Method }
            }
            Write-DeploymentLog -Message "Failed: $($endpoint.Description) - $errorMessage" -Level DEBUG
        }
    }
    Write-DeploymentLog -Message "No working imaging endpoint found" -Level WARN
    return $null
}

function Initialize-FCConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Url,
        [Parameter(Mandatory = $true)] [string]$Username,
        [Parameter(Mandatory = $true)] [string]$Password
    )
    Write-DeploymentLog -Message "Connecting to Foundation Central at $Url" -Level INFO
    $base64Creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))
    $headers = @{ "Authorization" = "Basic $base64Creds"; "Content-Type" = "application/json"; "Accept" = "application/json" }
    $PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
    $PSDefaultParameterValues['Invoke-WebRequest:SkipCertificateCheck'] = $true
    try {
        Write-DeploymentLog -Message "Auto-discovering Foundation Central API endpoint..." -Level INFO
        $connection = $null
        $workingEndpoint = Test-FCEndpoint -BaseUrl $Url -Headers $headers
        if ($workingEndpoint) {
            Write-DeploymentLog -Message "Found working endpoint: $($workingEndpoint.Path)" -Level SUCCESS
            Write-DeploymentLog -Message "Using HTTP method: $($workingEndpoint.Method)" -Level INFO
            Write-DeploymentLog -Message "Base API path: $($workingEndpoint.BasePath)" -Level INFO
            $imagingEndpoint = Test-ImagingEndpoint -BaseUrl $Url -Headers $headers
            $connection = @{
                Headers = $headers; BaseUrl = $Url; Username = $Username; Connected = $true
                APIPath = $workingEndpoint.BasePath; APIMethod = $workingEndpoint.Method; ImagingEndpoint = $imagingEndpoint
            }
        } else {
            Write-DeploymentLog -Message "Auto-discovery failed, trying standard endpoints..." -Level WARN
            $testUri = "$Url/api/foundation_central/v3/imaged_nodes/list"
            $body = @{kind = "imaged_node"; length = 1 } | ConvertTo-Json
            try {
                $null = Invoke-RestMethod -Uri $testUri -Method POST -Headers $headers -Body $body -TimeoutSec 30 -ErrorAction Stop
                Write-DeploymentLog -Message "Connected using Foundation Central v3 API" -Level INFO
                $connection = @{ Headers = $headers; BaseUrl = $Url; Username = $Username; Connected = $true; APIPath = "/api/foundation_central/v3"; APIMethod = "POST" }
            } catch {
                Write-DeploymentLog -Message "Primary API path failed, trying alternative..." -Level WARN
                $testUri = "$Url/foundation_central/v3/imaged_nodes/list"
                try {
                    $null = Invoke-RestMethod -Uri $testUri -Method POST -Headers $headers -Body $body -TimeoutSec 30 -ErrorAction Stop
                    Write-DeploymentLog -Message "Connected using alternative API path (no /api prefix)" -Level INFO
                    $connection = @{ Headers = $headers; BaseUrl = $Url; Username = $Username; Connected = $true; APIPath = "/foundation_central/v3"; APIMethod = "POST" }
                } catch {
                    Write-DeploymentLog -Message "Alternative API path also failed: $_" -Level ERROR
                    throw "Cannot connect to Foundation Central at $Url. Please verify the URL and credentials."
                }
            }
        }
        Write-DeploymentLog -Message "Foundation Central connection successful" -Level SUCCESS
        return $connection
    } catch {
        Write-DeploymentLog -Message "Failed to connect to Foundation Central: $_" -Level ERROR
        throw $_
    }
}

#endregion

#region Node Discovery Functions

function Get-AvailableNodes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [hashtable]$FCConnection)
    Write-DeploymentLog -Message "Discovering available nodes in Foundation Central" -Level INFO
    $apiEndpoints = @()
    if ($FCConnection.APIPath -and $FCConnection.APIMethod) {
        $detectedPath = $FCConnection.APIPath
        if ($detectedPath -notmatch 'imaged_nodes') { $detectedPath = "$detectedPath/imaged_nodes/list" }
        $detectedPath = $detectedPath -replace '/list/list$', '/list'
        $apiEndpoints += @{ Path = $detectedPath; Method = $FCConnection.APIMethod }
        Write-DeploymentLog -Message "Using detected endpoint from connection: $($FCConnection.APIMethod) $detectedPath" -Level INFO
    } else {
        Write-DeploymentLog -Message "WARNING: No detected endpoint in FCConnection - using fallbacks" -Level WARN
    }
    $apiEndpoints += @(
        @{ Path = "/api/fc/v1/imaged_nodes/list"; Method = "GET" },
        @{ Path = "/api/fc/v1/imaged_nodes/list"; Method = "POST" },
        @{ Path = "/api/fc/v1/imaged_nodes"; Method = "GET" },
        @{ Path = "/dm/foundation_central/api/imaged_nodes/list"; Method = "GET" },
        @{ Path = "/api/foundation_central/v3/imaged_nodes/list"; Method = "POST" },
        @{ Path = "/api/nutanix/v3/imaged_nodes/list"; Method = "POST" }
    )
    Write-DeploymentLog -Message "Will try $($apiEndpoints.Count) API endpoints for node discovery" -Level INFO
    $response = $null
    foreach ($endpoint in $apiEndpoints) {
        $uri = "$($FCConnection.BaseUrl)$($endpoint.Path)"; $method = $endpoint.Method
        Write-DeploymentLog -Message "Trying API endpoint: $method $uri" -Level INFO
        try {
            $params = @{ Uri = $uri; Method = $method; Headers = $FCConnection.Headers; TimeoutSec = 30; ContentType = "application/json"; ErrorAction = 'Stop' }
            if ($method -eq "POST") {
                $body = @{ kind = "imaged_node"; length = 500 } | ConvertTo-Json
                $params['Body'] = $body
            }
            $testResponse = Invoke-RestMethod @params
            if ($testResponse -is [string] -and $testResponse -match '<!doctype html>') { continue }
            if ($testResponse -is [PSCustomObject] -and $testResponse.PSObject.Properties.Name -contains 'error') { continue }
            $response = $testResponse
            Write-DeploymentLog -Message "Successfully connected to API endpoint: $method $uri" -Level SUCCESS
            break
        } catch {
            $errorMsg = $_.Exception.Message
            if ($_.ErrorDetails.Message) { $errorMsg += " - Details: $($_.ErrorDetails.Message)" }
            Write-DeploymentLog -Message "Endpoint failed: $method $uri - $errorMsg" -Level WARN
        }
    }
    if (-not $response) { throw "Failed to connect to Foundation Central API. Tried multiple endpoints without success." }
    $logsPath = if ($script:LogsDirectory) { $script:LogsDirectory } else { Join-Path $PSScriptRoot 'Logs' }
    if (-not (Test-Path $logsPath)) { New-Item -Path $logsPath -ItemType Directory -Force | Out-Null }
    $debugFile = Join-Path $logsPath "fc_response_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    try { $response | ConvertTo-Json -Depth 10 | Out-File $debugFile -Encoding UTF8 -Force; Invoke-LogRotation -Directory $logsPath -Pattern 'fc_response_*.json' } catch {}
    $nodeArray = if ($response.imaged_nodes) { $response.imaged_nodes } elseif ($response.entities) { $response.entities } else { @() }
    $totalNodes = $nodeArray.Count
    Write-DeploymentLog -Message "Received $totalNodes total nodes from Foundation Central" -Level INFO
    if ($response) {
        Write-Host "`n=== FOUNDATION CENTRAL API RESPONSE STRUCTURE ===" -ForegroundColor Cyan
        Write-Host "Properties: $($response.PSObject.Properties.Name -join ', ')" -ForegroundColor Yellow
        Write-Host "Nodes Count: $totalNodes" -ForegroundColor Yellow
        Write-Host "===================================================`n" -ForegroundColor Cyan
    }
    if ($totalNodes -eq 0) { return @() }
    $availableNodes = @()
    foreach ($node in $nodeArray) {
        $nodeSerial = if ($node.node_serial) { $node.node_serial } elseif ($node.status.node_serial) { $node.status.node_serial } else { "NO_SERIAL" }
        $nodeState = if ($node.node_state) { $node.node_state } elseif ($node.status.node_state) { $node.status.node_state } else { "NO_STATE" }
        $available = if ($null -ne $node.available) { $node.available } elseif ($node.status.state -eq "AVAILABLE") { $true } else { $false }
        if ($nodeSerial -ne "NO_SERIAL") {
            $isCurrentlyImaging = ($nodeState -eq "STATE_IMAGING")
            if (-not $isCurrentlyImaging -and $available) {
                $nodeUuid = if ($node.imaged_node_uuid) { $node.imaged_node_uuid } elseif ($node.metadata.uuid) { $node.metadata.uuid } else { "" }
                $ipmiIp = if ($node.ipmi_ip) { $node.ipmi_ip } elseif ($node.status.ipmi_ip) { $node.status.ipmi_ip } else { "" }
                $ipmiGateway = if ($node.ipmi_gateway) { $node.ipmi_gateway } elseif ($node.status.ipmi_gateway) { $node.status.ipmi_gateway } else { "" }
                $ipmiNetmask = if ($node.ipmi_netmask) { $node.ipmi_netmask } elseif ($node.status.ipmi_netmask) { $node.status.ipmi_netmask } else { "" }
                $model = if ($node.model) { $node.model } elseif ($node.status.model) { $node.status.model } else { "" }
                $hypervisor = if ($node.hypervisor_type) { $node.hypervisor_type } elseif ($node.status.hypervisor) { $node.status.hypervisor } else { "" }
                $cvmIp = if ($node.cvm_ip) { $node.cvm_ip } elseif ($node.status.cvm_ip) { $node.status.cvm_ip } else { "" }
                $foundationVersion = if ($node.foundation_version) { $node.foundation_version } elseif ($node.status.foundation_version) { $node.status.foundation_version } else { "" }
                $aosVersion = if ($node.aos_version) { $node.aos_version } elseif ($node.status.aos_version) { $node.status.aos_version } else { "" }
                $availableNodes += [PSCustomObject]@{
                    node_uuid = $nodeUuid; node_serial = $nodeSerial; ipmi_ip = $ipmiIp; ipmi_gateway = $ipmiGateway
                    ipmi_netmask = $ipmiNetmask; model = $model; hypervisor = $hypervisor; cvm_ip = $cvmIp
                    foundation_version = $foundationVersion; aos_version = $aosVersion; node_state = $nodeState
                }
                Write-DeploymentLog -Message "Added node: $nodeSerial (State: $nodeState, Model: $model)" -Level INFO
            }
        }
    }
    Write-DeploymentLog -Message "Found $($availableNodes.Count) available nodes" -Level INFO
    return $availableNodes
}

#endregion

#region Validation Functions

function Test-ConfigurationFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$ConfigPath)
    $errors = @(); $warnings = @()
    if (-not (Test-Path $ConfigPath)) { $errors += "Configuration file not found: $ConfigPath"; return @{ Valid = $false; Errors = $errors; Warnings = $warnings } }
    try { $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch { $errors += "Invalid JSON format: $_"; return @{ Valid = $false; Errors = $errors; Warnings = $warnings } }
    $requiredFields = @('clusterName','foundation_central','network','dns_servers','ntp_servers','aos_version','hypervisor')
    foreach ($field in $requiredFields) { if (-not $config.$field) { $errors += "Missing required field: $field" } }
    if ($config.foundation_central) {
        if (-not $config.foundation_central.url) { $errors += "Missing foundation_central.url" }
        if (-not $config.foundation_central.username) { $errors += "Missing foundation_central.username" }
        if (-not $config.foundation_central.password) { $errors += "Missing foundation_central.password" }
        if ($config.foundation_central.password -match "CHANGE_ME") { $warnings += "Default password detected - remember to change after deployment" }
    }
    if ($config.network) {
        if (-not $config.network.ip_prefix) { $errors += "Missing network.ip_prefix" }
        if (-not $config.network.subnet_mask) { $errors += "Missing network.subnet_mask" }
        if (-not $config.network.gateway_last_octet) { $errors += "Missing network.gateway_last_octet" }
        $expectedNodeCount = if ($config.network.nodes) { @($config.network.nodes).Count } else { 0 }
        if (-not $config.network.hostnames -or ($expectedNodeCount -gt 0 -and $config.network.hostnames.Count -ne $expectedNodeCount)) { $errors += "network.hostnames must contain exactly $expectedNodeCount hostnames (one per node)" }
        if ($config.network.ip_prefix -and -not (Test-IPPrefixFormat -IPPrefix $config.network.ip_prefix)) { $errors += "Invalid IP prefix format: $($config.network.ip_prefix)" }
        if ($config.network.vlan_id) { if ($config.network.vlan_id -lt 1 -or $config.network.vlan_id -gt 4094) { $errors += "Invalid VLAN ID: $($config.network.vlan_id). Must be between 1 and 4094" } }
    }
    if ($config.dns_servers) { foreach ($dns in $config.dns_servers) { if (-not (Test-IPAddressFormat -IPAddress $dns)) { $errors += "Invalid DNS server IP format: $dns" } } }
    if (-not $config.ipmi) { $warnings += "IPMI credentials not specified - will use defaults (ADMIN/ADMIN)" }
    return @{ Valid = ($errors.Count -eq 0); Errors = $errors; Warnings = $warnings; Config = $config }
}

function Test-NetworkConnectivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$IPAddresses,
        [Parameter(Mandatory = $false)] [string]$WitnessIP = $null,
        [string[]]$DNSServers, [switch]$CheckIPMI,
        [Parameter(Mandatory = $false)] [array]$IPMIIPs
    )
    $results = @{ Passed = @(); Failed = @(); Skipped = @() }
    Write-DeploymentLog -Message "Checking if Cluster VIP is available..." -Level INFO
    if (Test-IPInUse -IPAddress $IPAddresses.ClusterVIP) { $results.Failed += "Cluster VIP $($IPAddresses.ClusterVIP) is already in use" }
    else { $results.Passed += "Cluster VIP $($IPAddresses.ClusterVIP) is available" }
    Write-DeploymentLog -Message "Checking gateway connectivity..." -Level INFO
    if (Test-IPInUse -IPAddress $IPAddresses.Gateway -TimeoutMilliseconds 2000) { $results.Passed += "Gateway $($IPAddresses.Gateway) is reachable" }
    else { $results.Failed += "Gateway $($IPAddresses.Gateway) is not reachable" }
    if ($DNSServers) {
        foreach ($dns in $DNSServers) {
            Write-DeploymentLog -Message "Checking DNS server $dns..." -Level INFO
            if (Test-IPInUse -IPAddress $dns -TimeoutMilliseconds 2000) { $results.Passed += "DNS server $dns is reachable" }
            else { $results.Failed += "DNS server $dns is not reachable" }
        }
    }
    if ($CheckIPMI) {
        Write-DeploymentLog -Message "Checking IPMI connectivity..." -Level INFO
        $ipmiIPsToCheck = if ($IPMIIPs -and $IPMIIPs.Count -ge 2) { $IPMIIPs } else { @($IPAddresses.Node1_IPMI, $IPAddresses.Node2_IPMI) }
        foreach ($ipmiIP in $ipmiIPsToCheck) {
            try {
                $tcpClient = New-Object System.Net.Sockets.TcpClient
                $connect = $tcpClient.BeginConnect($ipmiIP, 623, $null, $null)
                $wait = $connect.AsyncWaitHandle.WaitOne(2000, $false)
                if ($wait -and $tcpClient.Connected) { $results.Passed += "IPMI $ipmiIP port 623 is accessible" }
                else { $results.Failed += "IPMI $ipmiIP port 623 is not accessible" }
                $tcpClient.Close()
            } catch { $results.Failed += "IPMI $ipmiIP connectivity check failed: $_" }
        }
    }
    return $results
}

function Test-FoundationCentralReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$FCConnection,
        [Parameter(Mandatory = $true)] [string]$AOSVersion,
        [Parameter(Mandatory = $true)] [string]$Hypervisor
    )
    $results = @{ Passed = @(); Failed = @(); Warnings = @() }
    Write-DeploymentLog -Message "Checking AOS version availability..." -Level INFO
    try {
        $apiPath = if ($FCConnection.APIPath) { $FCConnection.APIPath } else { "/api/foundation_central/v3" }
        $uri = "$($FCConnection.BaseUrl)$apiPath/aos_packages/list"
        $body = @{ kind = "aos_package"; length = 100 } | ConvertTo-Json
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $FCConnection.Headers -Body $body -TimeoutSec 30 -ContentType "application/json"
        $aosFound = $false
        foreach ($entity in $response.entities) { if ($entity.status.version -like "*$AOSVersion*") { $aosFound = $true; break } }
        if ($aosFound) { $results.Passed += "AOS version $AOSVersion is available in FC" }
        else { $results.Warnings += "AOS version $AOSVersion not found locally in FC (using URL instead)" }
    } catch { $results.Warnings += "AOS packages endpoint not available (using aos_package_url from config)" }
    Write-DeploymentLog -Message "Checking hypervisor image availability..." -Level INFO
    try {
        $apiPath = if ($FCConnection.APIPath) { $FCConnection.APIPath } else { "/api/foundation_central/v3" }
        $uri = "$($FCConnection.BaseUrl)$apiPath/hypervisor_isos/list"
        $body = @{ kind = "hypervisor_iso"; length = 100 } | ConvertTo-Json
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $FCConnection.Headers -Body $body -TimeoutSec 30 -ContentType "application/json"
        $hypervisorFound = $false
        foreach ($entity in $response.entities) { if ($entity.status.hypervisor -eq $Hypervisor.ToLower()) { $hypervisorFound = $true; break } }
        if ($hypervisorFound) { $results.Passed += "$Hypervisor ISO is available in FC" }
        else { $results.Warnings += "$Hypervisor ISO not found locally in FC (will be downloaded if needed)" }
    } catch { $results.Warnings += "Hypervisor ISOs endpoint not available (FC will download as needed)" }
    if ($results.Passed.Count -eq 0) { $results.Passed += "Foundation Central API is accessible and responding" }
    return $results
}

#endregion

#region Imaging Functions

function New-ImagingRequestBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Config,
        [Parameter(Mandatory = $true)]  [hashtable]$IPAddresses,
        [Parameter(Mandatory = $true)]  [hashtable]$Nodes,
        [Parameter(Mandatory = $false)] [bool]$SkipImaging = $false,
        [Parameter(Mandatory = $false)] [bool]$SkipClusterFormation = $false
    )
    $shouldImage = -not $SkipImaging
    if ($SkipImaging) {
        Write-DeploymentLog -Message "Skip imaging enabled - nodes will not be re-imaged" -Level INFO
    } else {
        Write-DeploymentLog -Message "Full imaging enabled (image_now=true) - nodes will be imaged from scratch" -Level INFO
    }
    if ($SkipClusterFormation) {
        Write-DeploymentLog -Message "SkipClusterFormation=true (Mode=ImageOnly): cluster formation fields will be omitted from request body" -Level INFO
    }
    $hypervisorTypeMapping = @{ 'AHV' = 'kvm'; 'ESX' = 'esx'; 'ESXI' = 'esx'; 'HYPERV' = 'hyperv'; 'HYPER-V' = 'hyperv' }
    $hypervisorType = $Config.hypervisor.ToUpper()
    $apiHypervisorType = if ($hypervisorTypeMapping.ContainsKey($hypervisorType)) { $hypervisorTypeMapping[$hypervisorType] } else { $hypervisorType.ToLower() }
    $hypervisorIsoDetails = @{ hypervisor_type = $apiHypervisorType }
    if ($Config.hypervisor_iso_url) {
        $hypervisorIsoDetails['url'] = $Config.hypervisor_iso_url
        Write-DeploymentLog -Message "Using hypervisor ISO from URL: $($Config.hypervisor_iso_url)" -Level INFO
    }
    $commonNetworkSettings = @{
        cvm_dns_servers = $Config.dns_servers; hypervisor_dns_servers = $Config.dns_servers
        cvm_ntp_servers = $Config.ntp_servers; hypervisor_ntp_servers = $Config.ntp_servers
    }
    $cfgVlanId = if ($Config.network.PSObject.Properties['vlan_id'] -and $null -ne $Config.network.vlan_id -and [string]$Config.network.vlan_id -ne '') { [int]$Config.network.vlan_id } else { $null }
    if ($null -ne $cfgVlanId -and $cfgVlanId -gt 0) { $commonNetworkSettings['hypervisor_vlan_id'] = $cfgVlanId }
    $body = @{
        aos_package_url = $Config.aos_package_url; hypervisor_iso_details = $hypervisorIsoDetails
        timezone = $Config.timezone; common_network_settings = $commonNetworkSettings; nodes_list = @()
    }
    $nodePositionLabels = @('A','B','C','D','E','F','G','H')
    $configNodes = @($Config.network.nodes)
    $nodesList = @()
    for ($i = 0; $i -lt $configNodes.Count; $i++) {
        $nc = $configNodes[$i]; $nKey = "Node$($i + 1)"
        $disc = if ($Nodes.ContainsKey($nKey) -and $Nodes[$nKey]) { $Nodes[$nKey] } else { $null }
        $hvIP  = if ($IPAddresses.ContainsKey("${nKey}_Hypervisor")) { $IPAddresses["${nKey}_Hypervisor"] } else { $nc.hypervisor_ip }
        $cvmIP = if ($IPAddresses.ContainsKey("${nKey}_CVM"))        { $IPAddresses["${nKey}_CVM"]        } else { $nc.cvm_ip }
        $cfgIpmiGw = if ($Config.network.PSObject.Properties['ipmi_gateway'] -and $Config.network.ipmi_gateway) { $Config.network.ipmi_gateway } else { '' }
        $cfgIpmiNm = if ($Config.network.PSObject.Properties['ipmi_netmask'] -and $Config.network.ipmi_netmask) { $Config.network.ipmi_netmask } else { '' }
        $nodeIpmiIp = if ($disc -and $disc.ipmi_ip) { $disc.ipmi_ip } elseif ($nc.PSObject.Properties['ipmi_ip'] -and $nc.ipmi_ip) { $nc.ipmi_ip } else { '' }
        $nodeIpmiGw = if ($disc -and $disc.ipmi_gateway) { $disc.ipmi_gateway } elseif ($nc.PSObject.Properties['ipmi_gateway'] -and $nc.ipmi_gateway) { $nc.ipmi_gateway } elseif ($cfgIpmiGw) { $cfgIpmiGw } else { '' }
        $nodeIpmiNm = if ($disc -and $disc.ipmi_netmask) { $disc.ipmi_netmask } elseif ($nc.PSObject.Properties['ipmi_netmask'] -and $nc.ipmi_netmask) { $nc.ipmi_netmask } elseif ($cfgIpmiNm) { $cfgIpmiNm } else { '' }
        $nodeEntry = @{
            node_position = $nodePositionLabels[$i]; node_serial = if ($disc) { $disc.node_serial } else { $nc.serial }
            imaged_node_uuid = if ($disc) { $disc.node_uuid } else { '' }
            hypervisor_hostname = $Config.network.hostnames[$i]; hypervisor_ip = $hvIP
            hypervisor_gateway = $IPAddresses.Gateway; hypervisor_netmask = $Config.network.subnet_mask
            hypervisor_type = $apiHypervisorType; cvm_ip = $cvmIP
            cvm_gateway = $IPAddresses.Gateway; cvm_netmask = $Config.network.subnet_mask; image_now = $shouldImage
        }
        if ($nodeIpmiIp) { $nodeEntry['ipmi_ip'] = $nodeIpmiIp }
        if ($nodeIpmiGw) { $nodeEntry['ipmi_gateway'] = $nodeIpmiGw }
        if ($nodeIpmiNm) { $nodeEntry['ipmi_netmask'] = $nodeIpmiNm }
        $nodesList += $nodeEntry
    }
    $body['nodes_list'] = $nodesList
    $vlanId = if ($Config.network.PSObject.Properties['vlan_id'] -and $null -ne $Config.network.vlan_id -and [string]$Config.network.vlan_id -ne '') { [int]$Config.network.vlan_id } else { $null }
    if ($null -ne $vlanId -and $vlanId -gt 0) {
        foreach ($node in $body.nodes_list) { $node['cvm_vlan_id'] = $vlanId; $node['hypervisor_vlan_id'] = $vlanId }
        Write-DeploymentLog -Message "VLAN ID $vlanId (cvm_vlan_id + hypervisor_vlan_id) added to all nodes in imaging body" -Level INFO
    }
    if ($hypervisorIsoDetails) { $body['hypervisor_isos'] = @(@{ url = $hypervisorIsoDetails['url']; hypervisor_type = $hypervisorIsoDetails['hypervisor_type'] }) }
    $body['redundancy_factor'] = [Math]::Min(2, @($Config.network.nodes).Count)
    $body['cluster_type'] = 'hyperconverged'
    if (-not $SkipClusterFormation) {
        $body['cluster_name'] = $Config.clusterName; $body['cluster_external_ip'] = $IPAddresses.ClusterVIP; $body['skip_cluster_creation'] = $false
    } else { $body['skip_cluster_creation'] = $true }
    $logsPath = if ($script:LogsDirectory) { $script:LogsDirectory } else { Join-Path $PSScriptRoot 'Logs' }
    if (-not (Test-Path $logsPath)) { New-Item -Path $logsPath -ItemType Directory -Force | Out-Null }
    $bodyLogFile = Join-Path $logsPath "imaging_body_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    try {
        if ($bodyLogFile -and $bodyLogFile -ne "") {
            $body | ConvertTo-Json -Depth 10 | Out-File $bodyLogFile -Encoding UTF8 -Force
            Write-DeploymentLog -Message "Imaging request body saved to: $bodyLogFile" -Level INFO
            Invoke-LogRotation -Directory $logsPath -Pattern 'imaging_body_*.json'
        }
    } catch { Write-DeploymentLog -Message "WARNING: Could not save imaging body to file: $_" -Level WARN }
    return $body
}

function Start-ClusterImaging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$FCConnection,
        [Parameter(Mandatory = $true)] [hashtable]$ImagingBody
    )
    Write-DeploymentLog -Message "Starting cluster imaging job..." -Level INFO
    if ($FCConnection.ImagingEndpoint -and $FCConnection.ImagingEndpoint.Path) {
        $uri = "$($FCConnection.BaseUrl)$($FCConnection.ImagingEndpoint.Path)"
        Write-DeploymentLog -Message "Using discovered imaging endpoint: $($FCConnection.ImagingEndpoint.Path)" -Level INFO
    } else {
        $uri = "$($FCConnection.BaseUrl)/api/foundation_central/v3/imaged_clusters"
        Write-DeploymentLog -Message "Using default v3 imaging endpoint (discovery not available)" -Level WARN
    }
    $bodyJson = $ImagingBody | ConvertTo-Json -Depth 10
    Write-DeploymentLog -Message "Imaging POST endpoint: $uri" -Level INFO
    Write-DeploymentLog -Message "Imaging POST body: $bodyJson" -Level DEBUG
    try {
        $requestHeaders = $FCConnection.Headers.Clone()
        $requestHeaders['NTNX-Request-Id'] = [System.Guid]::NewGuid().ToString()
        Write-DeploymentLog -Message "Using NTNX-Request-Id: $($requestHeaders['NTNX-Request-Id'])" -Level DEBUG
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $requestHeaders -Body $bodyJson -TimeoutSec 60
        Write-DeploymentLog -Message "Full imaging response received: $($response | ConvertTo-Json -Depth 5 -Compress)" -Level DEBUG
        $jobUUID = if ($response.imaged_cluster_uuid) { $response.imaged_cluster_uuid }
                   elseif ($response.metadata.uuid) { $response.metadata.uuid }
                   elseif ($response.uuid) { $response.uuid }
                   else {
                       Write-DeploymentLog -Message "UUID not in POST response, attempting to find cluster by name..." -Level INFO
                       Start-Sleep -Seconds 2
                       try {
                           $listUri = "$($FCConnection.BaseUrl)/api/fc/v1/imaged_clusters/list"
                           $listBody = @{} | ConvertTo-Json
                           $listResponse = Invoke-RestMethod -Uri $listUri -Method POST -Headers $FCConnection.Headers -Body $listBody -TimeoutSec 30
                           $clusterName = $ImagingBody.cluster_name
                           $matchingCluster = $listResponse.imaged_clusters | Where-Object { $_.cluster_name -eq $clusterName } |
                               Sort-Object -Property { if ($_.created_timestamp) { [DateTime]$_.created_timestamp } else { [DateTime]::MinValue } } -Descending | Select-Object -First 1
                           if ($matchingCluster) {
                               if ($matchingCluster.imaged_cluster_uuid) { $matchingCluster.imaged_cluster_uuid }
                               elseif ($matchingCluster.metadata.uuid) { $matchingCluster.metadata.uuid }
                               else { throw "Could not find cluster '$clusterName' in list of imaged clusters" }
                           } else { throw "Could not find cluster '$clusterName' in list of imaged clusters" }
                       } catch { throw "Could not get cluster UUID from POST response or list endpoint" }
                   }
        Write-DeploymentLog -Message "Imaging job created: $jobUUID" -Level SUCCESS
        return $jobUUID
    } catch {
        Write-DeploymentLog -Message "Failed to start imaging: $_" -Level ERROR
        throw "Failed to start imaging: $_"
    }
}

function Get-ImagingProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$FCConnection,
        [Parameter(Mandatory = $true)] [string]$JobUUID
    )
    $apiPath = if ($FCConnection.APIPath) { $FCConnection.APIPath } else { "/api/foundation_central/v3" }
    $isV1 = $apiPath -match "/fc/v1"

    function ConvertTo-ProgressObject($obj) {
        if (-not $obj) { return $null }
        $statusObj = if ($obj.PSObject.Properties['status']) { $obj.status } else { $obj }
        $clusterStatus = if ($statusObj.cluster_status) { $statusObj.cluster_status } elseif ($obj.cluster_status) { $obj.cluster_status } else { $null }
        $percentComplete = if ($null -ne $clusterStatus.aggregate_percent_complete) { $clusterStatus.aggregate_percent_complete }
                           elseif ($null -ne $statusObj.aggregate_percent_complete) { $statusObj.aggregate_percent_complete }
                           elseif ($null -ne $obj.aggregate_percent_complete) { $obj.aggregate_percent_complete } else { $null }
        $nodeList = if ($clusterStatus.node_progress_details) { $clusterStatus.node_progress_details }
                    elseif ($statusObj.node_status_list) { $statusObj.node_status_list }
                    elseif ($statusObj.node_progress_list) { $statusObj.node_progress_list }
                    elseif ($obj.node_status_list) { $obj.node_status_list }
                    elseif ($obj.node_progress_list) { $obj.node_progress_list } else { $null }
        $currentOp = if ($statusObj.current_operation) { $statusObj.current_operation } elseif ($obj.current_operation) { $obj.current_operation } else { $null }
        $derivedState = $null
        if ($clusterStatus) {
            if ($null -ne $percentComplete -and [double]$percentComplete -ge 100) { $derivedState = 'COMPLETED' }
            elseif ($clusterStatus.cluster_creation_started) { $derivedState = 'ClusterFormation' }
            elseif ($clusterStatus.deployment_started) { $derivedState = 'Imaging' }
            elseif ($clusterStatus.intent_picked_up) { $derivedState = 'Preparing' }
            elseif ($null -ne $percentComplete) { $derivedState = 'Queued' }
        }
        $v3Phase = $clusterStatus.cluster_creation_phase
        $state = if (-not [string]::IsNullOrEmpty($v3Phase)) { $v3Phase } else { $derivedState }
        return @{ State = $state; PercentComplete = $percentComplete; CurrentOperation = $currentOp; ClusterStatus = $clusterStatus; NodeProgress = $nodeList }
    }

    if ($isV1) {
        $listUri = "$($FCConnection.BaseUrl)$apiPath/imaged_clusters/list"
        try {
            $body = @{} | ConvertTo-Json
            $listResponse = Invoke-RestMethod -Uri $listUri -Method POST -Headers $FCConnection.Headers -Body $body -ContentType 'application/json' -TimeoutSec 30
            $clusterObj = $listResponse.imaged_clusters | Where-Object { $_.imaged_cluster_uuid -eq $JobUUID } | Select-Object -First 1
            if ($clusterObj) {
                if (-not $script:_progressDumpDone) {
                    $script:_progressDumpDone = $true
                    $dumpDir = if ($script:LogsDirectory) { $script:LogsDirectory } else { Join-Path $PSScriptRoot 'Logs' }
                    $dumpPath = Join-Path $dumpDir "fc_progress_raw_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
                    try { $clusterObj | ConvertTo-Json -Depth 20 | Out-File -FilePath $dumpPath -Encoding UTF8; Invoke-LogRotation -Directory $dumpDir -Pattern 'fc_progress_raw_*.json' } catch {}
                }
                return (ConvertTo-ProgressObject $clusterObj)
            }
        } catch { Write-DeploymentLog -Message "Failed to get imaging progress via FC v1 list: $_" -Level WARN }
    }
    $directUri = "$($FCConnection.BaseUrl)$apiPath/imaged_clusters/$JobUUID"
    try {
        $response = Invoke-RestMethod -Uri $directUri -Method GET -Headers $FCConnection.Headers -TimeoutSec 30
        $progress = ConvertTo-ProgressObject $response
        if ($progress.State -or $progress.PercentComplete -or $progress.CurrentOperation) { return $progress }
    } catch {}
    if (-not ($apiPath -match "foundation_central/v3")) {
        $v3Uri = "$($FCConnection.BaseUrl)/api/foundation_central/v3/imaged_clusters/$JobUUID"
        try {
            $response = Invoke-RestMethod -Uri $v3Uri -Method GET -Headers $FCConnection.Headers -TimeoutSec 30
            $progress = ConvertTo-ProgressObject $response
            if ($progress.State -or $progress.PercentComplete -or $progress.CurrentOperation) { return $progress }
        } catch {}
    }
    Write-DeploymentLog -Message "Could not retrieve imaging progress for UUID $JobUUID from any endpoint" -Level WARN
    return $null
}

function Wait-ImagingCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$FCConnection,
        [Parameter(Mandatory = $true)] [string]$JobUUID,
        [int]$PollIntervalSeconds = 30,
        [int]$TimeoutMinutes = 120
    )
    Write-DeploymentLog -Message "Waiting for imaging completion (timeout: $TimeoutMinutes minutes)..." -Level INFO
    $startTime = Get-Date; $timeout = $startTime.AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $timeout) {
        $progress = Get-ImagingProgress -FCConnection $FCConnection -JobUUID $JobUUID
        if ($progress) {
            $state = $progress.State; $percent = $progress.PercentComplete; $operation = $progress.CurrentOperation; $nodeProgress = $progress.NodeProgress
            $clusterPhase = if ($progress.ClusterStatus) { $progress.ClusterStatus.cluster_creation_phase } else { $null }
            $hasProgress = (-not [string]::IsNullOrEmpty($state)) -or ($null -ne $percent) -or (-not [string]::IsNullOrEmpty($operation)) -or (-not [string]::IsNullOrEmpty($clusterPhase))
            if (-not $hasProgress) {
                $elapsed = [int]((Get-Date) - $startTime).TotalMinutes
                Write-Host ("[----            Waiting for FC to report progress...            ----] ($elapsed min)") -ForegroundColor Yellow
            } else {
                $pct = if ($null -ne $percent) { [double]$percent } else { 0 }
                $barLength = 40; $filledLength = [int]($barLength * ($pct / 100))
                $bar = ('#' * $filledLength).PadRight($barLength, '-')
                $elapsed = [int]((Get-Date) - $startTime).TotalMinutes
                $displayState = if (-not [string]::IsNullOrEmpty($state)) { $state } elseif (-not [string]::IsNullOrEmpty($clusterPhase)) { "ClusterFormation:$clusterPhase" } else { "Running" }
                $displayOp = if (-not [string]::IsNullOrEmpty($operation)) { " $operation" } else { "" }
                $nodeStr = ""
                if ($nodeProgress) {
                    $msgs = foreach ($node in $nodeProgress) {
                        $msg = if ($node.node_state) { $node.node_state } elseif ($node.state) { $node.state } elseif ($node.message) { $node.message } elseif ($node.status) { $node.status } else { $null }
                        if ($msg) { $msg }
                    }
                    $uniqueMsgs = @($msgs | Select-Object -Unique)
                    if ($uniqueMsgs.Count -gt 0) { $nodeStr = "  $($uniqueMsgs -join ' | ')" }
                }
                Write-Host ("[{0}] {1,3}% - {2}{3} ({4} min){5}" -f $bar, $pct, $displayState, $displayOp, $elapsed, $nodeStr) -ForegroundColor Cyan
                Write-DeploymentLog -Message ("[{0}] {1,3}% - {2}{3} ({4} min){5}" -f $bar, $pct, $displayState, $displayOp, $elapsed, $nodeStr) -Level INFO
            }
            $completedStates = @('COMPLETED', 'SUCCEEDED', 'SUCCESS', 'COMPLETE')
            $failedStates = @('FAILED', 'ERROR', 'FAILURE', 'ABORTED')
            $isComplete = ($percent -eq 100) -or ($completedStates -contains $state) -or ($completedStates -contains $clusterPhase)
            $isFailed = ($failedStates -contains $state) -or ($failedStates -contains $clusterPhase)
            if ($isComplete) {
                Write-DeploymentLog -Message "Imaging/cluster formation completed successfully! (state=$state, phase=$clusterPhase, pct=$percent)" -Level SUCCESS
                return @{ Success = $true; Progress = $progress }
            }
            if ($isFailed) {
                Write-DeploymentLog -Message "Imaging/cluster formation failed: $operation (state=$state, phase=$clusterPhase)" -Level ERROR
                return @{ Success = $false; Progress = $progress; Error = $operation }
            }
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    Write-DeploymentLog -Message "Imaging timeout after $TimeoutMinutes minutes" -Level ERROR
    return @{ Success = $false; Error = "Timeout after $TimeoutMinutes minutes" }
}

#endregion

#region Display Functions

function Show-DeploymentPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$Config,
        [Parameter(Mandatory = $true)] [hashtable]$IPAddresses,
        [hashtable]$Nodes,
        [ValidateSet('ImageOnly', 'ClusterOnly', 'Both')] [string]$Mode = 'Both'
    )
    $modeDescription = switch ($Mode) {
        'ImageOnly'   { 'Image nodes only  (no cluster formed)' }
        'ClusterOnly' { 'Cluster only       (existing image re-used, image_now=false)' }
        'Both'        { 'Bare metal deployment (image + cluster)' }
    }
    $configNodes = @($Config.network.nodes)
    $nodeLines = ""
    for ($i = 0; $i -lt $configNodes.Count; $i++) {
        $nKey = "Node$($i + 1)"
        $hostname = if ($Config.network.hostnames -and $Config.network.hostnames.Count -gt $i) { $Config.network.hostnames[$i] } else { $configNodes[$i].hostname }
        $serial = if ($Nodes -and $Nodes[$nKey]) { $Nodes[$nKey].node_serial } else { "[Discovery pending]" }
        $model = if ($Nodes -and $Nodes[$nKey]) { $Nodes[$nKey].model } else { "[Discovery pending]" }
        $ipmiIp = if ($IPAddresses.ContainsKey("${nKey}_IPMI")) { $IPAddresses["${nKey}_IPMI"] } else { "N/A" }
        $cvmIp = if ($IPAddresses.ContainsKey("${nKey}_CVM")) { $IPAddresses["${nKey}_CVM"] } else { $configNodes[$i].cvm_ip }
        $hvIp = if ($IPAddresses.ContainsKey("${nKey}_Hypervisor")) { $IPAddresses["${nKey}_Hypervisor"] } else { $configNodes[$i].hypervisor_ip }
        $nodeLines += @"

Node $($i + 1):
  Hostname:          $hostname
  Serial:            $serial
  Model:             $model
  IPMI:              $ipmiIp
  CVM IP:            $cvmIp
  Hypervisor IP:     $hvIp
"@
    }
    $vlanLine = if ($Config.network.vlan_id) { "$($Config.network.vlan_id)" } else { "N/A (untagged)" }
    $plan = @"

═══════════════════════════════════════════════════════════════
                    DEPLOYMENT PLAN
═══════════════════════════════════════════════════════════════

Operation Mode:    $Mode — $modeDescription

Cluster Configuration:
  Name:              $($Config.clusterName)
  IP Prefix:         $($Config.network.ip_prefix)
  VLAN:              $vlanLine
  
Auto-Generated Network IPs:
  Cluster VIP:       $($IPAddresses.ClusterVIP)
  Gateway:           $($IPAddresses.Gateway)
  Subnet Mask:       $($Config.network.subnet_mask)
  $nodeLines
Software:
  AOS Version:       $($Config.aos_version)
  Hypervisor:        $($Config.hypervisor)
  Timezone:          $($Config.timezone)
  
Services:
  DNS:               $($Config.dns_servers -join ', ')
  NTP:               $($Config.ntp_servers -join ', ')
  
Storage:
  Container:         $($Config.storage_container_name)

═══════════════════════════════════════════════════════════════
"@
    Write-Host $plan
}

#endregion

#region Historical Timings Functions

function Update-HistoricalTimings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$ClusterName,
        [Parameter(Mandatory = $true)] [hashtable]$PhaseTimings,
        [Parameter(Mandatory = $true)] [int]$TotalDurationMinutes,
        [Parameter(Mandatory = $true)] [bool]$Success,
        [string]$AOSVersion,
        [string]$Path = (Join-Path $PSScriptRoot 'historical-timings.json')
    )
    $history = @{ deployments = @(); statistics = @{ total_deployments = 0; successful_deployments = 0; average_duration_minutes = 0 } }
    if (Test-Path $Path) { try { $history = Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable } catch {} }
    $newRecord = @{
        cluster_name = $ClusterName; deployment_date = (Get-Date).ToString("o")
        total_duration_minutes = $TotalDurationMinutes; phases = $PhaseTimings
        node_count = 2; aos_version = $AOSVersion; success = $Success
    }
    $history.deployments += $newRecord
    $history.statistics.total_deployments = $history.deployments.Count
    $history.statistics.successful_deployments = ($history.deployments | Where-Object { $_.success }).Count
    $successfulDeployments = $history.deployments | Where-Object { $_.success }
    if ($successfulDeployments.Count -gt 0) {
        $history.statistics.average_duration_minutes = [math]::Round(($successfulDeployments | Measure-Object -Property total_duration_minutes -Average).Average, 1)
        $history.statistics.fastest_deployment_minutes = ($successfulDeployments | Measure-Object -Property total_duration_minutes -Minimum).Minimum
        $history.statistics.slowest_deployment_minutes = ($successfulDeployments | Measure-Object -Property total_duration_minutes -Maximum).Maximum
    }
    $history | ConvertTo-Json -Depth 10 | Out-File -FilePath $Path -Encoding UTF8
    Write-DeploymentLog -Message "Historical timings updated" -Level DEBUG
}

#endregion

# ══════════════════════════════════════════════════════════════════════════════
# End of inline module functions
# ══════════════════════════════════════════════════════════════════════════════

#region Main Script

try {
    $scriptStartTime = Get-Date

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "    Nutanix Zero Touch Installation - Node Imaging (Test Prep) " -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    #region Phase 1: Load and Validate Configuration
    Write-Host "[PHASE 1] Loading and validating configuration..." -ForegroundColor Cyan
    Write-Host ""

    $configResult = Test-ConfigurationFile -ConfigPath $ConfigFile

    if (-not $configResult.Valid) {
        Write-Host "Configuration validation FAILED:" -ForegroundColor Red
        foreach ($err in $configResult.Errors) { Write-Host "  ✗ $err" -ForegroundColor Red }
        exit 1
    }

    $config = $configResult.Config

    if ($config.PSObject.Properties.Name -contains 'output_level') {
        $env:ZTIPS_OUTPUT_LEVEL = $config.output_level
        Write-Host "  ℹ Output level set to: $($config.output_level)" -ForegroundColor Gray
    } else {
        $env:ZTIPS_OUTPUT_LEVEL = 'verbose'
    }

    Write-Host "  ✓ Configuration file is valid" -ForegroundColor Green
    foreach ($warning in $configResult.Warnings) { Write-Host "  ⚠ $warning" -ForegroundColor Yellow }

    if (-not $SkipPasswordCheck) {
        if ($config.foundation_central.password.Length -lt 8) {
            Write-Host "  ✗ Password must be at least 8 characters" -ForegroundColor Red
            exit 1
        }
    }

    # URL expiry check
    $urlsToCheck = @{
        'aos_package_url'    = $config.aos_package_url
        'hypervisor_iso_url' = $config.hypervisor_iso_url
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($urlEntry in $urlsToCheck.GetEnumerator()) {
        $urlValue = $urlEntry.Value
        if (-not $urlValue) { continue }
        if ($urlValue -match '[?&]Expires=(\d+)') {
            $expires     = [long]$Matches[1]
            $expiresDate = [DateTimeOffset]::FromUnixTimeSeconds($expires).ToLocalTime()
            if ($expires -lt $now) {
                Write-Host "  ✗ Download URL er udløbet: $($urlEntry.Key)" -ForegroundColor Red
                Write-Host "    Udløb: $($expiresDate.ToString('dd-MM-yyyy HH:mm')) (lokal tid)" -ForegroundColor Red
                Write-Host "    Generer nye URLs fra Nutanix Portal før du fortsætter." -ForegroundColor Yellow
                exit 1
            } else {
                $hoursLeft = [math]::Round(($expires - $now) / 3600, 1)
                if ($hoursLeft -lt 24) {
                    Write-Host "  ⚠ URL udløber snart: $($urlEntry.Key) — om $hoursLeft timer ($($expiresDate.ToString('dd-MM-yyyy HH:mm')))" -ForegroundColor Yellow
                } else {
                    Write-Host "  ✓ URL gyldig: $($urlEntry.Key) — udløber $($expiresDate.ToString('dd-MM-yyyy HH:mm'))" -ForegroundColor Green
                }
            }
        } else {
            Write-Host "  ✓ URL gyldig: $($urlEntry.Key) — ingen udløbsdato (permanent link)" -ForegroundColor Green
        }
    }

    # Initialize logging — use clusterName if present, else a fixed label
    $logClusterName = if ($config.PSObject.Properties.Name -contains 'clusterName' -and $config.clusterName) { $config.clusterName } else { 'TESTIMAGING' }
    $logFile = Initialize-DeploymentLog -ClusterName $logClusterName -LogDirectory $LogsDirectory -MaxLogFiles $MaxLogFiles
    Write-DeploymentLog -Message "Test imaging started (Mode=ImageOnly, ForceReimage=true)" -Level INFO

    # Generate IP addresses
    $ipmiIPs = @()
    if ($config.network.ipmi_ips -and $config.network.ipmi_ips.Count -ge 2) {
        $ipmiIPs = $config.network.ipmi_ips
    }

    # ImageOnly: cluster VIP is optional
    $clusterVIP = $null
    if ($config.PSObject.Properties.Name -contains 'network' -and
        $config.network.PSObject.Properties.Name -contains 'cluster_vip' -and
        $config.network.cluster_vip) {
        $clusterVIP = $config.network.cluster_vip
    }

    $ipAddresses = Get-IPAddresses `
        -IPPrefix          $config.network.ip_prefix `
        -GatewayLastOctet  $config.network.gateway_last_octet `
        -ClusterVIP        $clusterVIP `
        -Nodes             $config.network.nodes `
        -IPMIIPs           $ipmiIPs

    Write-DeploymentLog -Message "IP addresses generated from prefix $($config.network.ip_prefix)" -Level INFO
    Write-Host ""
    #endregion

    #region Phase 2: Connect to Foundation Central
    Write-Host "[PHASE 2] Connecting to Foundation Central..." -ForegroundColor Cyan
    Write-Host ""

    try {
        $fcConnection = Initialize-FCConnection `
            -Url      $config.foundation_central.url `
            -Username $config.foundation_central.username `
            -Password $config.foundation_central.password
        Write-Host "  ✓ Connected to Foundation Central" -ForegroundColor Green
    }
    catch {
        Write-Host "  ✗ Failed to connect: $_" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    #endregion

    #region Phase 3: Discovery
    Write-Host "[PHASE 3] Discovering nodes..." -ForegroundColor Cyan
    Write-Host ""

    try {
        $availableNodes = Get-AvailableNodes -FCConnection $fcConnection
        Write-Host "  ✓ Found $($availableNodes.Count) available nodes" -ForegroundColor Green

        if (-not $availableNodes -or $availableNodes.Count -eq 0) {
            Write-Host ""
            Write-Host "  ╔════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
            Write-Host "  ║                    NO NODES AVAILABLE IN FOUNDATION CENTRAL                ║" -ForegroundColor Red
            Write-Host "  ╚════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
            Write-Host ""
            Write-Host "  Foundation Central reports 0 nodes available. Verify:" -ForegroundColor Yellow
            Write-Host "    • All nodes are powered ON" -ForegroundColor White
            Write-Host "    • IPMI network is connected and reachable from FC" -ForegroundColor White
            if ($config.network.ipmi_ips -and $config.network.ipmi_ips.Count -gt 0) {
                Write-Host "    • IPMI IPs: $($config.network.ipmi_ips -join ', ')" -ForegroundColor White
            }
            Write-Host "    • Foundation Central: $($config.foundation_central.url)" -ForegroundColor White
            Write-Host ""
            if ($config.network.nodes -and @($config.network.nodes).Count -ge 1) {
                Write-Host "  Expected nodes:" -ForegroundColor Yellow
                $nIdx = 0
                foreach ($cn in @($config.network.nodes)) {
                    $nIdx++
                    Write-Host "    Node $nIdx`: $($cn.hostname) (Serial: $($cn.serial))" -ForegroundColor White
                }
            }
            Write-Host ""
            Write-DeploymentLog -Message "CRITICAL: No nodes available in Foundation Central" -Level ERROR
            throw "No nodes available in Foundation Central. Cannot proceed with imaging."
        }

        # Node matching by serial number
        $configNodeList = @($config.network.nodes)
        Write-Host ""
        Write-Host "  Using serial number-based node matching..." -ForegroundColor Cyan
        Write-Host "  Searching for serials: $($configNodeList.serial -join ', ')" -ForegroundColor White

        $matchedNodes = @{}
        for ($ni = 0; $ni -lt $configNodeList.Count; $ni++) {
            $ser   = $configNodeList[$ni].serial
            $nKey  = "Node$($ni + 1)"
            $match = $availableNodes | Where-Object { $_.node_serial -eq $ser }
            if (-not $match) {
                Write-DeploymentLog -Message "ERROR: Node with serial '$ser' not found. Available: $($availableNodes.node_serial -join ', ')" -Level ERROR
                throw "Node with serial '$ser' not found in Foundation Central. Verify the node is powered on and discovered."
            }
            Write-DeploymentLog -Message "Node $($ni+1) matched: Serial=$($match.node_serial), Model=$($match.model), UUID=$($match.node_uuid)" -Level SUCCESS
            $matchedNodes[$nKey] = $match
        }
        $nodes = $matchedNodes

        for ($ni = 0; $ni -lt $configNodeList.Count; $ni++) {
            $nKey = "Node$($ni + 1)"
            Write-Host "  ✓ Node $($ni+1): Serial=$($nodes[$nKey].node_serial), Model=$($nodes[$nKey].model), UUID=$($nodes[$nKey].node_uuid)" -ForegroundColor Green
        }

        # Clean node objects — keep uuid/serial and preserve IPMI fields from FC discovery
        $cleanNodes = @{}
        for ($ni = 0; $ni -lt $configNodeList.Count; $ni++) {
            $nKey      = "Node$($ni + 1)"
            $disc      = $nodes[$nKey]
            $cleanNode = [PSCustomObject]@{ node_uuid = $disc.node_uuid; node_serial = $disc.node_serial }
            if ($disc.PSObject.Properties['ipmi_ip']      -and $disc.ipmi_ip)      { $cleanNode | Add-Member -NotePropertyName 'ipmi_ip'      -NotePropertyValue $disc.ipmi_ip }
            if ($disc.PSObject.Properties['ipmi_gateway'] -and $disc.ipmi_gateway) { $cleanNode | Add-Member -NotePropertyName 'ipmi_gateway' -NotePropertyValue $disc.ipmi_gateway }
            if ($disc.PSObject.Properties['ipmi_netmask'] -and $disc.ipmi_netmask) { $cleanNode | Add-Member -NotePropertyName 'ipmi_netmask' -NotePropertyValue $disc.ipmi_netmask }
            $cleanNodes[$nKey] = $cleanNode
        }
        $nodes = $cleanNodes

        Write-Host ""
        Write-Host "  ⚠ ForceReimage: All nodes will be RE-IMAGED via Foundation Central (DATA LOSS)" -ForegroundColor Yellow
        Write-DeploymentLog -Message "Imaging decision: ForceReimage always on — nodes will be wiped and imaged" -Level INFO
    }
    catch {
        Write-Host "  ✗ Discovery failed: $_" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    #endregion

    #region Phase 4: Validation
    Write-Host "[PHASE 4] Running pre-imaging validation..." -ForegroundColor Cyan
    Write-Host ""

    # Foundation Central port validation
    Write-Host "Foundation Central Port Validation:" -ForegroundColor White
    $fcIP = $null
    if ($config.foundation_central.url -match "https?://([^:/]+)") { $fcIP = $matches[1] }

    if ($fcIP) {
        try {
            $tcpClient  = New-Object System.Net.Sockets.TcpClient
            $connection = $tcpClient.BeginConnect($fcIP, 9440, $null, $null)
            $wait       = $connection.AsyncWaitHandle.WaitOne(3000, $false)
            if ($wait -and $tcpClient.Connected) {
                Write-Host "  ✓ Port 9440 (Foundation Central) accessible on $fcIP" -ForegroundColor Green
                $tcpClient.Close()
            } else {
                Write-Host "  ✗ Port 9440 not accessible on $fcIP" -ForegroundColor Red
                $tcpClient.Close()
                throw "Port 9440 required for Foundation Central communication"
            }
        }
        catch {
            Write-Host "  ✗ Port 9440 test failed: $_" -ForegroundColor Red
            exit 1
        }

        if (Test-IPInUse -IPAddress $fcIP -TimeoutMilliseconds 2000) {
            Write-Host "  ✓ ICMP (Ping) responding to Foundation Central" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ ICMP (Ping) not responding to Foundation Central" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ⚠ Could not extract IP from Foundation Central URL" -ForegroundColor Yellow
    }

    Write-Host ""

    # Network validation
    Write-Host "Network Validation:" -ForegroundColor White
    $ipmiIPsForValidation = $null
    $skipIPMIValidation   = $false
    if ($config.network.ipmi_ips -and @($config.network.ipmi_ips | Where-Object { $_ -and $_.Trim() -ne "" }).Count -ge 2) {
        $ipmiIPsForValidation = $config.network.ipmi_ips
    } else {
        $skipIPMIValidation = $true
    }

    if (-not $skipIPMIValidation) {
        $networkResults = Test-NetworkConnectivity -IPAddresses $ipAddresses -WitnessIP $null -DNSServers $config.dns_servers -CheckIPMI -IPMIIPs $ipmiIPsForValidation
    } else {
        $networkResults = Test-NetworkConnectivity -IPAddresses $ipAddresses -WitnessIP $null -DNSServers $config.dns_servers
    }

    foreach ($pass in $networkResults.Passed)   { Write-Host "  ✓ $pass" -ForegroundColor Green  }
    foreach ($warn in $networkResults.Warnings) { Write-Host "  ⚠ $warn" -ForegroundColor Yellow }
    foreach ($fail in $networkResults.Failed)   { Write-Host "  ✗ $fail" -ForegroundColor Red    }

    if ($networkResults.Failed.Count -gt 0) {
        Write-Host ""; Write-Host "Network validation failed. Cannot proceed." -ForegroundColor Red; exit 1
    }

    Write-Host ""

    # Foundation Central readiness
    Write-Host "Foundation Central Validation:" -ForegroundColor White
    $fcResults = Test-FoundationCentralReadiness -FCConnection $fcConnection -AOSVersion $config.aos_version -Hypervisor $config.hypervisor

    foreach ($pass in $fcResults.Passed)   { Write-Host "  ✓ $pass" -ForegroundColor Green  }
    foreach ($warn in $fcResults.Warnings) { Write-Host "  ⚠ $warn" -ForegroundColor Yellow }
    foreach ($fail in $fcResults.Failed)   { Write-Host "  ✗ $fail" -ForegroundColor Red    }

    if ($fcResults.Failed.Count -gt 0) {
        Write-Host ""; Write-Host "Foundation Central validation failed. Cannot proceed." -ForegroundColor Red; exit 1
    }

    Write-Host ""
    Write-Host "  ✓ All critical validation checks passed!" -ForegroundColor Green
    Write-Host ""
    #endregion

    #region Phase 5: Display Deployment Plan
    Show-DeploymentPlan -Config $config -IPAddresses $ipAddresses -Nodes $nodes -Mode $Mode
    #endregion

    #region Phase 5.5: Build and Validate Imaging Body
    Write-Host ""
    Write-Host "[PHASE 5.5] Building imaging request body..." -ForegroundColor Cyan
    Write-Host ""

    # Mode=ImageOnly: skip_cluster_formation = true — nodes are imaged, no cluster formed
    $skipImaging          = $false
    $skipClusterFormation = $true
    $imagingBody = New-ImagingRequestBody `
        -Config               $config `
        -IPAddresses          $ipAddresses `
        -Nodes                $nodes `
        -SkipImaging          $skipImaging `
        -SkipClusterFormation $skipClusterFormation

    Write-Host "Imaging Request Body Validation:" -ForegroundColor White
    Write-Host "  Body Type:              $($imagingBody.GetType().Name)" -ForegroundColor Gray
    Write-Host "  Body Keys:              $($imagingBody.Keys.Count) keys" -ForegroundColor Gray
    Write-Host "    └─ $($imagingBody.Keys -join ', ')" -ForegroundColor DarkGray
    Write-Host "  skip_cluster_formation: $($imagingBody.skip_cluster_formation)" -ForegroundColor Gray

    $bodyJson = $imagingBody | ConvertTo-Json -Depth 20 -Compress:$false
    Write-Host "  JSON Length:            $($bodyJson.Length) characters" -ForegroundColor Gray

    $validationIssues = @()
    if (-not $imagingBody.aos_package_url)                         { $validationIssues += "Missing aos_package_url" }
    if (-not $imagingBody.hypervisor_iso_details.hypervisor_type)  { $validationIssues += "Missing hypervisor_iso_details.hypervisor_type" }
    if ($imagingBody.hypervisor_iso_details.url) { Write-Host "  Hypervisor ISO:         $($imagingBody.hypervisor_iso_details.url)" -ForegroundColor Gray }
    if (-not $imagingBody.nodes_list -or $imagingBody.nodes_list.Count -eq 0) {
        $validationIssues += "Missing or empty nodes_list"
    } else {
        Write-Host "  Nodes:                  $($imagingBody.nodes_list.Count) nodes" -ForegroundColor Gray
        $nodeNum = 1
        foreach ($node in $imagingBody.nodes_list) {
            if (-not $node.node_serial) { $validationIssues += "Node $nodeNum missing node_serial" }
            else { Write-Host "    └─ Node $nodeNum Serial: $($node.node_serial)" -ForegroundColor DarkGray }
            $nodeNum++
        }
    }

    if ($validationIssues.Count -gt 0) {
        Write-Host ""
        Write-Host "  ✗ Body Validation Failed:" -ForegroundColor Red
        foreach ($issue in $validationIssues) { Write-Host "    - $issue" -ForegroundColor Red }
        Write-Host ""
        Write-Host "Full body JSON:" -ForegroundColor Yellow
        Write-Host $bodyJson -ForegroundColor Gray
        Write-Host ""
        Write-Host "Cannot proceed with invalid imaging request body." -ForegroundColor Red
        exit 1
    }

    Write-Host "  ✓ Body validation passed" -ForegroundColor Green
    Write-Host ""
    #endregion

    #region Dry-Run Check
    if ($DryRun) {
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "              DRY-RUN MODE - VALIDATION COMPLETE              " -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  ✓ All validation checks passed" -ForegroundColor Green
        Write-Host "  ✓ Imaging body validated and saved to log" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Imaging body log file:" -ForegroundColor White
        $logsDir   = Join-Path $PSScriptRoot 'Logs'
        $bodyFiles = Get-ChildItem -Path $logsDir -Filter "imaging_body_*.json" -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($bodyFiles) { Write-Host "    → $($bodyFiles.FullName)" -ForegroundColor Gray }
        Write-Host ""
        Write-Host "  [DRY-RUN] No changes were made to the environment" -ForegroundColor Yellow
        Write-Host "  [DRY-RUN] Remove -DryRun flag to proceed with actual imaging" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
        exit 0
    }
    #endregion

    #region Log File Information
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Log Information" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  ℹ Log file: $logFile" -ForegroundColor Gray
    Write-Host "  ℹ Mode=ImageOnly — nodes will be imaged, NO cluster will be formed" -ForegroundColor Cyan
    Write-Host ""
    #endregion

    #region Phase 6: User Confirmation
    if (-not $Force) {
        Write-Host ""
        Write-Host "  ═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  ℹ Validation completed - all necessary checks performed" -ForegroundColor White
        Write-Host "  ⚠ Nodes will be WIPED and re-imaged — data will be lost" -ForegroundColor Yellow
        Write-Host "  ℹ No cluster will be formed (Mode=ImageOnly)" -ForegroundColor Cyan
        Write-Host "  ═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""

        $proceedConfirm = (Read-Host "  Are you ready to start node imaging? (Y/N)").Trim().ToUpperInvariant()
        if ($proceedConfirm -ne 'Y') {
            Write-Host ""
            Write-Host "  Imaging cancelled by user." -ForegroundColor Red
            Write-DeploymentLog -Message "Imaging cancelled by user before start" -Level WARN
            exit 1
        }
    }
    #endregion

    #region Phase 7: Start Node Imaging
    Write-Host "[PHASE 7] Starting node imaging via Foundation Central..." -ForegroundColor Cyan
    Write-Host ""

    $jobUUID = $null
    try {
        $jobUUID = Start-ClusterImaging -FCConnection $fcConnection -ImagingBody $imagingBody
        $pollUrl = "$($fcConnection.BaseUrl)$($fcConnection.APIPath)/imaged_clusters/$jobUUID"
        Write-Host "  ✓ Imaging job created: $jobUUID" -ForegroundColor Green
        Write-Host "    Poll: $pollUrl" -ForegroundColor Gray
    }
    catch {
        Write-Host "  ✗ Failed to start imaging: $_" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    #endregion

    #region Phase 8: Wait for Imaging Completion
    Write-Host "[PHASE 8] Waiting for imaging completion..." -ForegroundColor Cyan
    Write-Host "(This typically takes 30-50 minutes)" -ForegroundColor Gray
    Write-Host ""

    $imagingResult = Wait-ImagingCompletion `
        -FCConnection        $fcConnection `
        -JobUUID             $jobUUID `
        -PollIntervalSeconds 30 `
        -TimeoutMinutes      120

    if (-not $imagingResult.Success) {
        Write-Host ""
        Write-Host "Imaging failed: $($imagingResult.Error)" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    #endregion

    #region Phase 9: Post-Imaging Notice
    Write-Host "[PHASE 9] Imaging complete." -ForegroundColor Cyan
    Write-Host "  ✓ All nodes have been imaged successfully." -ForegroundColor Green
    Write-Host "  ℹ Mode=ImageOnly: no cluster was formed." -ForegroundColor Cyan
    Write-Host "  ℹ To form a cluster, run: .\Deploy-Cluster.ps1 -ConfigFile .\Configs\DKLAB-3-deploy.json" -ForegroundColor White
    Write-DeploymentLog -Message "Phase 9: Imaging complete. No cluster formed (Mode=ImageOnly)." -Level INFO
    Write-Host ""
    #endregion

    #region Phase 10: Finalization
    $scriptEndTime = Get-Date
    $totalDuration = $scriptEndTime - $scriptStartTime

    try {
        Update-HistoricalTimings `
            -ClusterName          $logClusterName `
            -PhaseTimings         @{ total = [int]$totalDuration.TotalMinutes } `
            -TotalDurationMinutes ([int]$totalDuration.TotalMinutes) `
            -Success              $true `
            -AOSVersion           $config.aos_version
    } catch {
        Write-Host "  ⚠ Could not update historical timings: $_" -ForegroundColor Yellow
        Write-DeploymentLog -Message "Warning: Failed to update historical timings: $_" -Level WARN
    }
    #endregion
}
catch {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host "                      IMAGING FAILED                           " -ForegroundColor Red
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Stack Trace:" -ForegroundColor Yellow
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
    Write-Host ""
    Write-Host "Please review the error, fix any issues, and restart the imaging." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

#endregion


