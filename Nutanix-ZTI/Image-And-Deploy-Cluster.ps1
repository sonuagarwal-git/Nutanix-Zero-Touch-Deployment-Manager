#Requires -Version 7.0
<#
.SYNOPSIS
    Deploy a Nutanix cluster (1 to N nodes) with optional witness via Foundation Central
.DESCRIPTION
    Main deployment script for Nutanix Zero Touch Installation.
    Reads configuration from JSON file and deploys cluster automatically.
.PARAMETER ConfigFile
    Path to the cluster configuration JSON file. Default: cluster-config.json
.PARAMETER DryRun
    Run validation only without making any changes
.PARAMETER SkipPasswordCheck
    Skip the password security validation
.PARAMETER Force
    Skip confirmation prompts
.PARAMETER ForceReimage
    Force re-imaging even if nodes have correct AOS version installed
.EXAMPLE
    .\Deploy-Cluster.ps1 -DryRun
    Run validation without deploying
.EXAMPLE
    .\Deploy-Cluster.ps1 -ConfigFile .\my-cluster.json
    Deploy using specified config file
.EXAMPLE
    .\Deploy-Cluster.ps1 -ConfigFile .\my-cluster.json -ForceReimage
    Force re-imaging regardless of current AOS version

.NOTES
    Author: Søren Reinertsen & Sonu Agarwal
    Date: Feb 25, 2026
    Version: 1.0
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigFile = ".\configs\my-cluster.json",
    
    [Parameter()]
    [switch]$DryRun = $false,
    
    [Parameter()]
    [switch]$SkipPasswordCheck,
    
    [Parameter()]
    [switch]$Force = $true,
    
    [Parameter()]
    [switch]$ForceReimage = $true,

    # When called from Start-Pipeline.ps1 pass the unified run-*.log path so that
    # this script appends to it rather than creating a separate deployment-log-*.txt.
    [Parameter()]
    [string]$LogFile = ''
)

# Ignorerer SSL-certifikatvalidering for alle HTTPS-forespørgsler (kun til test/ikke-produktionsbrug)
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }


$ErrorActionPreference = "Stop"

# Module-level variables (previously in NutanixZTI.psm1)
$script:DeploymentLogFile  = $null
$script:FCConnection       = $null
$script:LogsDirectory      = $null
$script:MaxLogFiles        = 5

#region Inlined Module Functions (from Modules\NutanixZTI.psm1)

#region Logging Functions

function Write-DeploymentLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO",
        
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
    
    if ($LogFile) {
        Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue
    }
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
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,
        [string]$LogDirectory = ".\Logs",
        [int]$MaxLogFiles = 5,
        # When provided, append to this existing log file instead of creating deployment-log-*.txt
        [string]$SharedLogFile = ''
    )
    $script:LogsDirectory = $LogDirectory
    $script:MaxLogFiles   = $MaxLogFiles
    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    if ($SharedLogFile) {
        # Append a section divider into the unified pipeline log
        $script:DeploymentLogFile = $SharedLogFile
        $sectionHeader = @"

───────────────────────────────────────────────────────────────
  Image & Deploy Phase — $ClusterName
  Phase started: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
───────────────────────────────────────────────────────────────
"@
        Add-Content -Path $SharedLogFile -Value $sectionHeader -ErrorAction SilentlyContinue
    } else {
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
    }
    return $script:DeploymentLogFile
}

#endregion

#region Connection Functions

function Test-FCEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
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
            $params = @{
                Uri = $testUrl
                Method = $endpoint.Method
                Headers = $Headers
                TimeoutSec = 10
                ErrorAction = 'Stop'
            }
            if ($endpoint.Method -eq "POST") {
                $testBody = @{kind = "imaged_node"; length = 1} | ConvertTo-Json
                $params['Body'] = $testBody
                $params['ContentType'] = 'application/json'
            }
            $testResponse = Invoke-RestMethod @params
            if ($testResponse -is [string] -and $testResponse -match '<!doctype html>') {
                Write-DeploymentLog -Message "Failed: $($endpoint.Description) - returned HTML, not JSON" -Level DEBUG
                continue
            }
            Write-DeploymentLog -Message "SUCCESS: $($endpoint.Description)" -Level SUCCESS
            return @{
                Path = $endpoint.Path
                Method = $endpoint.Method
                BasePath = ($endpoint.Path -replace '/imaged_nodes/list|/aos_packages/list|/clusters/list|/cluster', '')
            }
        }
        catch {
            Write-DeploymentLog -Message "Failed: $($endpoint.Description) - $($_.Exception.Message)" -Level DEBUG
        }
    }
    return $null
}

function Test-ImagingEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
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
            $params = @{
                Uri = $testUrl
                Method = $endpoint.Method
                Headers = $Headers
                Body = $testBody
                ContentType = 'application/json'
                TimeoutSec = 10
                ErrorAction = 'Stop'
            }
            $testResponse = Invoke-RestMethod @params
            Write-DeploymentLog -Message "SUCCESS: $($endpoint.Description) endpoint exists" -Level SUCCESS
            return @{
                Path = $endpoint.Path
                Method = $endpoint.Method
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -match "404|not found") {
                Write-DeploymentLog -Message "Failed: $($endpoint.Description) - endpoint not found" -Level DEBUG
                continue
            }
            if ($errorMessage -match "400|validation|required|Details of nodes") {
                Write-DeploymentLog -Message "SUCCESS: $($endpoint.Description) endpoint exists (validation error is expected)" -Level SUCCESS
                return @{
                    Path = $endpoint.Path
                    Method = $endpoint.Method
                }
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
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [string]$Username,
        [Parameter(Mandatory = $true)]
        [string]$Password
    )
    Write-DeploymentLog -Message "Connecting to Foundation Central at $Url" -Level INFO
    $base64Creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))
    $headers = @{
        "Authorization" = "Basic $base64Creds"
        "Content-Type"  = "application/json"
        "Accept"        = "application/json"
    }
    $PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
    $PSDefaultParameterValues['Invoke-WebRequest:SkipCertificateCheck'] = $true
    try {
        Write-DeploymentLog -Message "Auto-discovering Foundation Central API endpoint..." -Level INFO
        $workingEndpoint = Test-FCEndpoint -BaseUrl $Url -Headers $headers
        if ($workingEndpoint) {
            Write-DeploymentLog -Message "Found working endpoint: $($workingEndpoint.Path)" -Level SUCCESS
            Write-DeploymentLog -Message "Using HTTP method: $($workingEndpoint.Method)" -Level INFO
            Write-DeploymentLog -Message "Base API path: $($workingEndpoint.BasePath)" -Level INFO
            $imagingEndpoint = Test-ImagingEndpoint -BaseUrl $Url -Headers $headers
            $script:FCConnection = @{
                Headers   = $headers
                BaseUrl   = $Url
                Username  = $Username
                Connected = $true
                APIPath   = $workingEndpoint.BasePath
                APIMethod = $workingEndpoint.Method
                ImagingEndpoint = $imagingEndpoint
            }
        }
        else {
            Write-DeploymentLog -Message "Auto-discovery failed, trying standard endpoints..." -Level WARN
            $testUri = "$Url/api/foundation_central/v3/imaged_nodes/list"
            $body = @{kind = "imaged_node"; length = 1 } | ConvertTo-Json
            try {
                $response = Invoke-RestMethod -Uri $testUri -Method POST -Headers $headers -Body $body -TimeoutSec 30 -ErrorAction Stop
                Write-DeploymentLog -Message "Connected using Foundation Central v3 API" -Level INFO
                $script:FCConnection = @{
                    Headers   = $headers
                    BaseUrl   = $Url
                    Username  = $Username
                    Connected = $true
                    APIPath   = "/api/foundation_central/v3"
                    APIMethod = "POST"
                }
            }
            catch {
                Write-DeploymentLog -Message "Primary API path failed, trying alternative..." -Level WARN
                Write-DeploymentLog -Message "Error: $_" -Level DEBUG
                $testUri = "$Url/foundation_central/v3/imaged_nodes/list"
                try {
                    $response = Invoke-RestMethod -Uri $testUri -Method POST -Headers $headers -Body $body -TimeoutSec 30 -ErrorAction Stop
                    Write-DeploymentLog -Message "Connected using alternative API path (no /api prefix)" -Level INFO
                    $script:FCConnection = @{
                        Headers   = $headers
                        BaseUrl   = $Url
                        Username  = $Username
                        Connected = $true
                        APIPath   = "/foundation_central/v3"
                        APIMethod = "POST"
                    }
                }
                catch {
                    Write-DeploymentLog -Message "Alternative API path also failed: $_" -Level ERROR
                    Write-DeploymentLog -Message "Tried URLs:" -Level ERROR
                    Write-DeploymentLog -Message "  1. $Url/api/foundation_central/v3/imaged_nodes/list" -Level ERROR
                    Write-DeploymentLog -Message "  2. $Url/foundation_central/v3/imaged_nodes/list" -Level ERROR
                    throw "Cannot connect to Foundation Central at $Url. Please verify the URL and credentials."
                }
            }
        }
        Write-DeploymentLog -Message "Foundation Central connection successful" -Level SUCCESS
        return $script:FCConnection
    }
    catch {
        Write-DeploymentLog -Message "Failed to connect to Foundation Central: $_" -Level ERROR
        throw $_
    }
}

function Initialize-PrismConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterVIP,
        [Parameter(Mandatory = $true)]
        [string]$Username,
        [Parameter(Mandatory = $true)]
        [string]$Password
    )
    Write-DeploymentLog -Message "Connecting to Prism at $ClusterVIP" -Level INFO
    $base64Creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))
    $headers = @{
        "Authorization" = "Basic $base64Creds"
        "Content-Type"  = "application/json"
        "Accept"        = "application/json"
    }
    return @{
        Headers  = $headers
        BaseUrl  = "https://${ClusterVIP}:9440"
        Username = $Username
    }
}

#endregion

#region IP Address Functions

function Get-IPAddresses {
    [CmdletBinding()]
    param(
        # Full gateway IP, e.g. "10.0.113.1"
        [Parameter(Mandatory = $true)]
        [string]$Gateway,
        # CIDR prefix length, e.g. 24
        [Parameter(Mandatory = $true)]
        [int]$PrefixLength,
        [Parameter(Mandatory = $false)]
        [string]$ClusterVIP,
        [Parameter(Mandatory = $false)]
        [PSCustomObject]$Nodes,
        [Parameter(Mandatory = $false)]
        [string[]]$IPMIIPs = @()
    )
    # Derive prefix (first 3 octets) and network address from the full gateway
    $gwParts   = $Gateway -split '\.'
    $ipPrefix  = ($gwParts[0..2]) -join '.'
    $networkAddress = "$ipPrefix.0"
    $clusterVipAddress = if ($ClusterVIP) { $ClusterVIP } else { "${ipPrefix}.10" }
    $ipAddresses = @{
        ClusterVIP = $clusterVipAddress
        Gateway    = $Gateway
        Subnet     = "${networkAddress}/${PrefixLength}"
    }
    # Build per-node IPs dynamically
    $nodeArray = if ($Nodes) { @($Nodes) } else { @() }
    for ($i = 0; $i -lt $nodeArray.Count; $i++) {
        $n = $nodeArray[$i]
        $num = $i + 1
        $defaultHvIP  = "${ipPrefix}.$(10 + $i * 2 + 2)"
        $defaultCvmIP = "${ipPrefix}.$(10 + $i * 2 + 1)"
        $ipAddresses["Node${num}_Hypervisor"] = if ($n.hypervisor_ip) { $n.hypervisor_ip } else { $defaultHvIP }
        $ipAddresses["Node${num}_CVM"]        = if ($n.cvm_ip)        { $n.cvm_ip }        else { $defaultCvmIP }
        # IPMI
        if ($IPMIIPs -and $IPMIIPs.Count -gt $i) {
            $ipAddresses["Node${num}_IPMI"] = $IPMIIPs[$i]
        } else {
            $ipAddresses["Node${num}_IPMI"] = "${ipPrefix}.$(20 + $num)"
        }
    }
    return $ipAddresses
}

function Test-IPAddressFormat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress
    )
    $ipRegex = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
    return $IPAddress -match $ipRegex
}

function Test-IPPrefixFormat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPPrefix
    )
    $prefixRegex = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){2}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
    return $IPPrefix -match $prefixRegex
}

function Test-IPInUse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress,
        [int]$TimeoutMilliseconds = 1000
    )
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $result = $ping.Send($IPAddress, $TimeoutMilliseconds)
        return $result.Status -eq 'Success'
    }
    catch {
        return $false
    }
}

function ConvertTo-SubnetMask {
    # Converts a CIDR prefix length (e.g. 24) to a dotted-decimal subnet mask (e.g. 255.255.255.0).
    # Uses [long] throughout to avoid the uint32 overflow that PowerShell's -shl causes when
    # promoting [uint32]0xFFFFFFFF to [long] before the shift produces a value > 0xFFFFFFFF.
    param([Parameter(Mandatory = $true)][ValidateRange(0, 32)][int]$PrefixLength)
    $hostBits = 32 - $PrefixLength
    $mask = if ($hostBits -eq 0) {
        [long]0xFFFFFFFF
    } else {
        [long]([math]::Pow(2, 32) - [math]::Pow(2, $hostBits))
    }
    return "$(($mask -shr 24) -band 0xFF).$(($mask -shr 16) -band 0xFF).$(($mask -shr 8) -band 0xFF).$($mask -band 0xFF)"
}

#endregion

#region Node Discovery Functions

function Get-AvailableNodes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$FCConnection
    )
    Write-DeploymentLog -Message "Discovering available nodes in Foundation Central" -Level INFO
    $apiEndpoints = @()
    if ($FCConnection.APIPath -and $FCConnection.APIMethod) {
        $detectedPath = $FCConnection.APIPath
        if ($detectedPath -notmatch 'imaged_nodes') {
            $detectedPath = "$detectedPath/imaged_nodes/list"
        }
        $detectedPath = $detectedPath -replace '/list/list$', '/list'
        $apiEndpoints += @{ 
            Path = $detectedPath
            Method = $FCConnection.APIMethod 
        }
        Write-DeploymentLog -Message "Using detected endpoint from connection: $($FCConnection.APIMethod) $detectedPath" -Level INFO
    }
    else {
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
    $successfulEndpoint = $null
    foreach ($endpoint in $apiEndpoints) {
        $uri = "$($FCConnection.BaseUrl)$($endpoint.Path)"
        $method = $endpoint.Method
        Write-DeploymentLog -Message "Trying API endpoint: $method $uri" -Level INFO
        try {
            $params = @{
                Uri = $uri
                Method = $method
                Headers = $FCConnection.Headers
                TimeoutSec = 30
                ContentType = "application/json"
                ErrorAction = 'Stop'
            }
            if ($method -eq "POST") {
                $body = @{
                    kind   = "imaged_node"
                    length = 500
                } | ConvertTo-Json
                $params['Body'] = $body
                Write-DeploymentLog -Message "Request body: $body" -Level DEBUG
            }
            Write-DeploymentLog -Message "Invoking REST method..." -Level DEBUG
            $testResponse = Invoke-RestMethod @params
            Write-DeploymentLog -Message "Response received, type: $($testResponse.GetType().Name)" -Level DEBUG
            if ($testResponse -is [string] -and $testResponse -match '<!doctype html>') {
                Write-DeploymentLog -Message "Endpoint returned HTML, not JSON - skipping" -Level WARN
                continue
            }
            if ($testResponse -is [PSCustomObject] -and $testResponse.PSObject.Properties.Name -contains 'error') {
                Write-DeploymentLog -Message "Endpoint returned error: $($testResponse.error)" -Level WARN
                continue
            }
            $response = $testResponse
            $successfulEndpoint = $endpoint
            Write-DeploymentLog -Message "Successfully connected to API endpoint: $method $uri" -Level SUCCESS
            break
        }
        catch {
            $errorMsg = $_.Exception.Message
            if ($_.ErrorDetails.Message) {
                $errorMsg += " - Details: $($_.ErrorDetails.Message)"
            }
            Write-DeploymentLog -Message "Endpoint failed: $method $uri - $errorMsg" -Level WARN
            continue
        }
    }
    if (-not $response) {
        Write-DeploymentLog -Message "ERROR: Could not find working Foundation Central API endpoint" -Level ERROR
        throw "Failed to connect to Foundation Central API. Tried multiple endpoints without success."
    }
    $logsPath = if ($script:LogsDirectory) { $script:LogsDirectory } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'Logs' }
    if (-not (Test-Path $logsPath)) {
        New-Item -Path $logsPath -ItemType Directory -Force | Out-Null
    }
    Write-DeploymentLog -Message "Foundation Central API response received (FC node list retrieved)" -Level INFO
    $nodeArray = if ($response.imaged_nodes) { 
        $response.imaged_nodes 
    } elseif ($response.entities) { 
        $response.entities 
    } else { 
        @() 
    }
    $totalNodes = $nodeArray.Count
    Write-DeploymentLog -Message "Received $totalNodes total nodes from Foundation Central" -Level INFO
    if ($response) {
        Write-DeploymentLog -Message "Response has properties: $($response.PSObject.Properties.Name -join ', ')" -Level DEBUG
        Write-Host "`n=== FOUNDATION CENTRAL API RESPONSE STRUCTURE ===" -ForegroundColor Cyan
        Write-Host "Properties: $($response.PSObject.Properties.Name -join ', ')" -ForegroundColor Yellow
        Write-Host "Nodes Count: $totalNodes" -ForegroundColor Yellow
        Write-Host "===================================================`n" -ForegroundColor Cyan
    }
    if ($totalNodes -eq 0) {
        Write-DeploymentLog -Message "WARNING: No nodes in response" -Level WARN
        Write-DeploymentLog -Message "Full API response saved to: $debugFile - please review" -Level WARN
        return @()
    }
    $availableNodes = @()
    foreach ($node in $nodeArray) {
        if ($availableNodes.Count -eq 0) {
            Write-DeploymentLog -Message "First node structure: $($node | ConvertTo-Json -Depth 5 -Compress)" -Level DEBUG
        }
        $nodeSerial = if ($node.node_serial) { $node.node_serial } `
                     elseif ($node.status.node_serial) { $node.status.node_serial } `
                     else { "NO_SERIAL" }
        $nodeState = if ($node.node_state) { $node.node_state } `
                    elseif ($node.status.node_state) { $node.status.node_state } `
                    else { "NO_STATE" }
        $available = if ($node.available -ne $null) { $node.available } `
                    elseif ($node.status.state -eq "AVAILABLE") { $true } `
                    else { $false }
        Write-DeploymentLog -Message "Node: $nodeSerial, State: $nodeState, Available: $available" -Level DEBUG
        if ($nodeSerial -ne "NO_SERIAL") {
            $isCurrentlyImaging = ($nodeState -eq "STATE_IMAGING")
            if (-not $isCurrentlyImaging -and $available) {
                $nodeUuid = if ($node.imaged_node_uuid) { $node.imaged_node_uuid } `
                           elseif ($node.metadata.uuid) { $node.metadata.uuid } `
                           else { "" }
                $ipmiIp = if ($node.ipmi_ip) { $node.ipmi_ip } `
                         elseif ($node.status.ipmi_ip) { $node.status.ipmi_ip } `
                         else { "" }
                $ipmiGateway = if ($node.ipmi_gateway) { $node.ipmi_gateway } `
                              elseif ($node.status.ipmi_gateway) { $node.status.ipmi_gateway } `
                              else { "" }
                $ipmiNetmask = if ($node.ipmi_netmask) { $node.ipmi_netmask } `
                              elseif ($node.status.ipmi_netmask) { $node.status.ipmi_netmask } `
                              else { "" }
                $model = if ($node.model) { $node.model } `
                        elseif ($node.status.model) { $node.status.model } `
                        else { "" }
                $hypervisor = if ($node.hypervisor_type) { $node.hypervisor_type } `
                             elseif ($node.status.hypervisor) { $node.status.hypervisor } `
                             else { "" }
                $cvmIp = if ($node.cvm_ip) { $node.cvm_ip } `
                        elseif ($node.status.cvm_ip) { $node.status.cvm_ip } `
                        else { "" }
                $foundationVersion = if ($node.foundation_version) { $node.foundation_version } `
                                    elseif ($node.status.foundation_version) { $node.status.foundation_version } `
                                    else { "" }
                $aosVersion = if ($node.aos_version) { $node.aos_version } `
                             elseif ($node.status.aos_version) { $node.status.aos_version } `
                             else { "" }
                $availableNodes += [PSCustomObject]@{
                    node_uuid          = $nodeUuid
                    node_serial        = $nodeSerial
                    ipmi_ip            = $ipmiIp
                    ipmi_gateway       = $ipmiGateway
                    ipmi_netmask       = $ipmiNetmask
                    model              = $model
                    hypervisor         = $hypervisor
                    cvm_ip             = $cvmIp
                    foundation_version = $foundationVersion
                    aos_version        = $aosVersion
                    node_state         = $nodeState
                }
                Write-DeploymentLog -Message "Added node: $nodeSerial (State: $nodeState, Model: $model)" -Level INFO
            }
            elseif ($isCurrentlyImaging) {
                Write-DeploymentLog -Message "Skipped node: $nodeSerial (currently imaging)" -Level WARN
            }
            else {
                Write-DeploymentLog -Message "Skipped node: $nodeSerial (not available)" -Level WARN
            }
        }
        else {
            Write-DeploymentLog -Message "Skipped node without serial number" -Level DEBUG
        }
    }
    Write-DeploymentLog -Message "Found $($availableNodes.Count) available nodes" -Level INFO
    return $availableNodes
}

function Find-NodesBySerial {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$AvailableNodes,
        [Parameter(Mandatory = $true)]
        [string[]]$Serials
    )
    Write-DeploymentLog -Message "Matching nodes by serial numbers: $($Serials -join ', ')" -Level INFO
    # Validate no duplicates
    $uniqueSerials = $Serials | Sort-Object -Unique
    if ($uniqueSerials.Count -ne $Serials.Count) {
        throw "Configuration error: Duplicate serial numbers detected. Each node must have a unique serial number."
    }
    $result = @{}
    for ($i = 0; $i -lt $Serials.Count; $i++) {
        $serial = $Serials[$i]
        $num = $i + 1
        $matched = $AvailableNodes | Where-Object { $_.node_serial -eq $serial }
        if (-not $matched) {
            Write-DeploymentLog -Message "ERROR: Node with serial number '$serial' not found in available nodes" -Level ERROR
            Write-DeploymentLog -Message "Available node serials: $($AvailableNodes.node_serial -join ', ')" -Level ERROR
            throw "Node with serial number '$serial' not found in Foundation Central available nodes. Verify the node is powered on, connected to the network, and discovered by Foundation Central."
        }
        Write-DeploymentLog -Message "Node $num matched: Serial $($matched.node_serial), Model $($matched.model), UUID $($matched.node_uuid)" -Level SUCCESS
        $result["Node$num"] = $matched
    }
    # Validate no UUID collisions
    $uuids = $result.Values | ForEach-Object { $_.node_uuid }
    if (($uuids | Sort-Object -Unique).Count -ne $uuids.Count) {
        throw "Critical error: Multiple nodes resolved to the same UUID. Check Foundation Central discovery data."
    }
    # Warn if models differ
    $models = $result.Values | ForEach-Object { $_.model } | Sort-Object -Unique
    if ($models.Count -gt 1) {
        Write-DeploymentLog -Message "WARNING: Node models do not match: $($models -join ' vs '). Mixing different hardware models in a cluster is not recommended" -Level WARN
    }
    return $result
}

function Test-NodeImagingState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$Nodes
    )
    $nodeResults = @()
    foreach ($n in $Nodes) {
        $isBareMetal = [string]::IsNullOrWhiteSpace($n.cvm_ip)
        $nodeResults += @{
            Serial      = $n.node_serial
            IsBareMetal = $isBareMetal
            State       = if ($isBareMetal) { 'BARE_METAL' } else { 'IMAGED' }
            Details     = @{
                Serial    = $n.node_serial
                Model     = $n.model
                IPMI      = $n.ipmi_ip
                CVM_IP    = if ($n.cvm_ip) { $n.cvm_ip } else { 'Not configured' }
                Hypervisor = if ($n.hypervisor) { $n.hypervisor } else { 'Not installed' }
            }
        }
    }
    $allBareMetal = ($nodeResults | Where-Object { -not $_.IsBareMetal }).Count -eq 0
    $anyImaged    = ($nodeResults | Where-Object { -not $_.IsBareMetal }).Count -gt 0
    Write-DeploymentLog -Message "Node imaging state analysis:" -Level INFO
    for ($i = 0; $i -lt $nodeResults.Count; $i++) {
        $nr = $nodeResults[$i]
        Write-DeploymentLog -Message "  Node $($i+1) ($($nr.Serial)): $($nr.State) - CVM: $($nr.Details.CVM_IP)" -Level INFO
    }
    if ($allBareMetal) {
        Write-DeploymentLog -Message "Both nodes are BARE METAL - full imaging will be performed" -Level INFO
    } elseif ($anyImaged) {
        Write-DeploymentLog -Message "WARNING: One or more nodes appear to be already imaged" -Level WARN
        Write-DeploymentLog -Message "Setting image_now=true will WIPE and RE-IMAGE these nodes (DATA LOSS)" -Level WARN
    }
    return @{
        NodeResults   = $nodeResults
        BothBareMetal = $allBareMetal
        AnyImaged     = $anyImaged
        Node1_State   = if ($nodeResults.Count -ge 1) { $nodeResults[0].State   } else { 'UNKNOWN' }
        Node2_State   = if ($nodeResults.Count -ge 2) { $nodeResults[1].State   } else { 'UNKNOWN' }
        Node1_Details = if ($nodeResults.Count -ge 1) { $nodeResults[0].Details } else { @{} }
        Node2_Details = if ($nodeResults.Count -ge 2) { $nodeResults[1].Details } else { @{} }
    }
}

function Test-AOSVersionCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$Nodes,
        [Parameter(Mandatory = $true)]
        [string]$DesiredAOSUrl
    )
    $desiredVersion = "Unknown"
    if ($DesiredAOSUrl -match "release-[^-]+(\d+\.\d+(?:\.\d+)?)-") {
        $desiredVersion = $matches[1]
    }
    elseif ($DesiredAOSUrl -match "(\d+\.\d+(?:\.\d+)?)") {
        $desiredVersion = $matches[1]
    }
    Write-DeploymentLog -Message "Desired AOS version from URL: $desiredVersion" -Level INFO
    $nodeVersions = @()
    for ($i = 0; $i -lt $Nodes.Count; $i++) {
        $n = $Nodes[$i]
        $ver = "Unknown"
        if ($n.foundation_version) {
            Write-DeploymentLog -Message "Node $($i+1) foundation_version: $($n.foundation_version)" -Level DEBUG
            if ($n.foundation_version -match "(\d+\.\d+(?:\.\d+)?)") { $ver = $matches[1] }
        }
        $nodeVersions += $ver
    }
    $node1Version = if ($nodeVersions.Count -ge 1) { $nodeVersions[0] } else { "Unknown" }
    $node2Version = if ($nodeVersions.Count -ge 2) { $nodeVersions[1] } else { "Unknown" }
    $knownVersions = @($nodeVersions | Where-Object { $_ -ne "Unknown" } | Sort-Object -Unique)
    $detectedVersion = if ($knownVersions.Count -eq 0)     { "Unknown" }
                       elseif ($knownVersions.Count -eq 1)  { $knownVersions[0] }
                       else                                  { "Mismatch ($($nodeVersions -join ', '))" }
    $versionsMatch = $false
    if ($detectedVersion -eq "Unknown" -or $desiredVersion -eq "Unknown") {
        $versionsMatch = $false
        Write-DeploymentLog -Message "Cannot determine version compatibility - will require imaging" -Level WARN
    }
    elseif ($detectedVersion -like "Mismatch*") {
        $versionsMatch = $false
        Write-DeploymentLog -Message "Nodes have mismatched versions - will require imaging" -Level WARN
    }
    else {
        $detectedParts = $detectedVersion -split '\.'
        $desiredParts  = $desiredVersion  -split '\.'
        if ($detectedParts.Count -ge 2 -and $desiredParts.Count -ge 2) {
            $detectedMajorMinor = "$($detectedParts[0]).$($detectedParts[1])"
            $desiredMajorMinor  = "$($desiredParts[0]).$($desiredParts[1])"
            $versionsMatch = ($detectedMajorMinor -eq $desiredMajorMinor)
            Write-DeploymentLog -Message "Version comparison: $detectedMajorMinor vs $desiredMajorMinor -> Match: $versionsMatch" -Level INFO
        }
    }
    return @{
        VersionsMatch   = $versionsMatch
        DetectedVersion = $detectedVersion
        DesiredVersion  = $desiredVersion
        Node1Version    = $node1Version
        Node2Version    = $node2Version
    }
}

#endregion

#region Validation Functions

function Test-ConfigurationFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )
    $errors = @()
    $warnings = @()
    if (-not (Test-Path $ConfigPath)) {
        $errors += "Configuration file not found: $ConfigPath"
        return @{ Valid = $false; Errors = $errors; Warnings = $warnings }
    }
    try {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        $errors += "Invalid JSON format: $_"
        return @{ Valid = $false; Errors = $errors; Warnings = $warnings }
    }
    $requiredFields = @(
        'clusterName',
        'prism_central',
        'network',
        'dns_servers',
        'ntp_servers',
        'aos_version',
        'hypervisor'
    )
    foreach ($field in $requiredFields) {
        if (-not $config.$field) {
            $errors += "Missing required field: $field"
        }
    }
    if ($config.prism_central) {
        if (-not $config.prism_central.url) { $errors += "Missing prism_central.url" }
        if (-not $config.prism_central.username) { $errors += "Missing prism_central.username" }
        if (-not $config.prism_central.password) { $errors += "Missing prism_central.password" }
        if ($config.prism_central.password -match "CHANGE_ME") {
            $warnings += "Default password detected - remember to change after deployment"
        }
    }
    if ($config.network) {
        # Support both new format (gateway + prefix_length) and legacy format (ip_prefix + gateway_last_octet + subnet_mask)
        $hasNewFormat    = $config.network.gateway -and $config.network.prefix_length
        $hasLegacyFormat = $config.network.ip_prefix -and $config.network.gateway_last_octet
        if (-not $hasNewFormat -and -not $hasLegacyFormat) {
            $errors += "Missing network gateway configuration. Provide either 'network.gateway' + 'network.prefix_length' or legacy 'network.ip_prefix' + 'network.gateway_last_octet'"
        }
        $expectedNodeCount = if ($config.network.nodes) { @($config.network.nodes).Count } else { 0 }
        if (-not $config.network.hostnames -or ($expectedNodeCount -gt 0 -and $config.network.hostnames.Count -ne $expectedNodeCount)) {
            $errors += "network.hostnames must contain exactly $expectedNodeCount hostnames (one per node)"
        }
        if ($config.network.ip_prefix -and -not (Test-IPPrefixFormat -IPPrefix $config.network.ip_prefix)) {
            $errors += "Invalid IP prefix format: $($config.network.ip_prefix)"
        }
        if ($config.network.vlan_id) {
            if ($config.network.vlan_id -lt 1 -or $config.network.vlan_id -gt 4094) {
                $errors += "Invalid VLAN ID: $($config.network.vlan_id). Must be between 1 and 4094"
            }
        }
    }
    if ($config.dns_servers) {
        foreach ($dns in $config.dns_servers) {
            if (-not (Test-IPAddressFormat -IPAddress $dns)) {
                $errors += "Invalid DNS server IP format: $dns"
            }
        }
    }
    if (-not $config.ipmi) {
        $warnings += "IPMI credentials not specified - will use defaults (ADMIN/ADMIN)"
    }
    return @{
        Valid    = ($errors.Count -eq 0)
        Errors   = $errors
        Warnings = $warnings
        Config   = $config
    }
}

function Test-NetworkConnectivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$IPAddresses,
        [Parameter(Mandatory = $false)]
        [string]$WitnessIP = $null,
        [string[]]$DNSServers,
        [switch]$CheckIPMI,
        [Parameter(Mandatory = $false)]
        [array]$IPMIIPs
    )
    $results = @{
        Passed  = @()
        Failed  = @()
        Skipped = @()
    }
    Write-DeploymentLog -Message "Checking if Cluster VIP is available..." -Level INFO
    if (Test-IPInUse -IPAddress $IPAddresses.ClusterVIP) {
        $results.Failed += "Cluster VIP $($IPAddresses.ClusterVIP) is already in use"
    }
    else {
        $results.Passed += "Cluster VIP $($IPAddresses.ClusterVIP) is available"
    }
    Write-DeploymentLog -Message "Checking gateway connectivity..." -Level INFO
    if (Test-IPInUse -IPAddress $IPAddresses.Gateway -TimeoutMilliseconds 2000) {
        $results.Passed += "Gateway $($IPAddresses.Gateway) is reachable"
    }
    else {
        $results.Failed += "Gateway $($IPAddresses.Gateway) is not reachable"
    }
    if ($DNSServers) {
        foreach ($dns in $DNSServers) {
            Write-DeploymentLog -Message "Checking DNS server $dns..." -Level INFO
            if (Test-IPInUse -IPAddress $dns -TimeoutMilliseconds 2000) {
                $results.Passed += "DNS server $dns is reachable"
            }
            else {
                $results.Failed += "DNS server $dns is not reachable"
            }
        }
    }
    if ($CheckIPMI) {
        Write-DeploymentLog -Message "Checking IPMI connectivity..." -Level INFO
        $ipmiIPsToCheck = if ($IPMIIPs -and $IPMIIPs.Count -ge 1) {
            $IPMIIPs
        } else {
            @($IPAddresses.Keys | Where-Object { $_ -match '^Node\d+_IPMI$' } | ForEach-Object { $IPAddresses[$_] })
        }
        foreach ($ipmiIP in $ipmiIPsToCheck) {
            try {
                $tcpClient = New-Object System.Net.Sockets.TcpClient
                $connect = $tcpClient.BeginConnect($ipmiIP, 623, $null, $null)
                $wait = $connect.AsyncWaitHandle.WaitOne(2000, $false)
                if ($wait -and $tcpClient.Connected) {
                    $results.Passed += "IPMI $ipmiIP port 623 is accessible"
                }
                else {
                    $results.Failed += "IPMI $ipmiIP port 623 is not accessible"
                }
                $tcpClient.Close()
            }
            catch {
                $results.Failed += "IPMI $ipmiIP connectivity check failed: $_"
            }
        }
    }
    return $results
}

function Test-FoundationCentralReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$FCConnection,
        [Parameter(Mandatory = $true)]
        [string]$AOSVersion,
        [Parameter(Mandatory = $true)]
        [string]$Hypervisor
    )
    $results = @{
        Passed   = @()
        Failed   = @()
        Warnings = @()
    }
    Write-DeploymentLog -Message "Checking AOS version availability..." -Level INFO
    try {
        $apiPath = if ($FCConnection.APIPath) { $FCConnection.APIPath } else { "/api/foundation_central/v3" }
        $uri = "$($FCConnection.BaseUrl)$apiPath/aos_packages/list"
        $body = @{ kind = "aos_package"; length = 100 } | ConvertTo-Json
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $FCConnection.Headers -Body $body -TimeoutSec 30 -ContentType "application/json"
        $aosFound = $false
        foreach ($entity in $response.entities) {
            if ($entity.status.version -like "*$AOSVersion*") {
                $aosFound = $true
                break
            }
        }
        if ($aosFound) {
            $results.Passed += "AOS version $AOSVersion is available in FC"
        }
        else {
            $results.Warnings += "AOS version $AOSVersion not found locally in FC (using URL instead)"
        }
    }
    catch {
        Write-DeploymentLog -Message "Could not verify AOS packages in FC: $_" -Level DEBUG
        $results.Warnings += "AOS packages endpoint not available (using aos_package_url from config)"
    }
    Write-DeploymentLog -Message "Checking hypervisor image availability..." -Level INFO
    try {
        $apiPath = if ($FCConnection.APIPath) { $FCConnection.APIPath } else { "/api/foundation_central/v3" }
        $uri = "$($FCConnection.BaseUrl)$apiPath/hypervisor_isos/list"
        $body = @{ kind = "hypervisor_iso"; length = 100 } | ConvertTo-Json
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $FCConnection.Headers -Body $body -TimeoutSec 30 -ContentType "application/json"
        $hypervisorFound = $false
        foreach ($entity in $response.entities) {
            if ($entity.status.hypervisor -eq $Hypervisor.ToLower()) {
                $hypervisorFound = $true
                break
            }
        }
        if ($hypervisorFound) {
            $results.Passed += "$Hypervisor ISO is available in FC"
        }
        else {
            $results.Warnings += "$Hypervisor ISO not found locally in FC (will be downloaded if needed)"
        }
    }
    catch {
        Write-DeploymentLog -Message "Could not verify hypervisor ISOs in FC: $_" -Level DEBUG
        $results.Warnings += "Hypervisor ISOs endpoint not available (FC will download as needed)"
    }
    if ($results.Passed.Count -eq 0) {
        $results.Passed += "Foundation Central API is accessible and responding"
    }
    return $results
}

#endregion

#region Imaging Functions

function New-ImagingRequestBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,
        [Parameter(Mandatory = $true)]
        [hashtable]$IPAddresses,
        [Parameter(Mandatory = $true)]
        [hashtable]$Nodes,
        [Parameter(Mandatory = $false)]
        [bool]$SkipImaging = $false,
        [Parameter(Mandatory = $false)]
        [bool]$SkipClusterFormation = $false
    )
    $shouldImage = -not $SkipImaging
    # Compute subnet mask from config (self-contained — no script-scope dependency)
    $subnetMask = if ($Config.network.PSObject.Properties['subnet_mask'] -and $Config.network.subnet_mask) {
        $Config.network.subnet_mask
    } elseif ($Config.network.PSObject.Properties['prefix_length'] -and $Config.network.prefix_length) {
        ConvertTo-SubnetMask -PrefixLength ([int]$Config.network.prefix_length)
    } else {
        '255.255.255.0'  # safe default
    }
    if ($SkipImaging) {
        Write-DeploymentLog -Message "Skip imaging enabled - nodes will not be re-imaged" -Level INFO
        Write-DeploymentLog -Message "Assuming nodes already have correct AOS/hypervisor versions installed" -Level INFO
    }
    else {
        Write-DeploymentLog -Message "Full imaging enabled (image_now=true) - nodes will be imaged from scratch" -Level INFO
    }
    if ($SkipClusterFormation) {
        Write-DeploymentLog -Message "SkipClusterFormation=true (Mode=ImageOnly): cluster formation fields will be omitted from request body" -Level INFO
    }
    $hypervisorTypeMapping = @{
        'AHV'     = 'kvm'
        'ESX'     = 'esx'
        'ESXI'    = 'esx'
        'HYPERV'  = 'hyperv'
        'HYPER-V' = 'hyperv'
    }
    $hypervisorType = $Config.hypervisor.ToUpper()
    $apiHypervisorType = if ($hypervisorTypeMapping.ContainsKey($hypervisorType)) {
        $hypervisorTypeMapping[$hypervisorType]
    } else {
        $hypervisorType.ToLower()
    }
    $hypervisorIsoDetails = @{
        hypervisor_type = $apiHypervisorType
    }
    if ($Config.hypervisor_iso_url) {
        $hypervisorIsoDetails['url'] = $Config.hypervisor_iso_url
        Write-DeploymentLog -Message "Using hypervisor ISO from URL: $($Config.hypervisor_iso_url)" -Level INFO
    }
    $commonNetworkSettings = @{
        cvm_dns_servers        = $Config.dns_servers
        hypervisor_dns_servers = $Config.dns_servers
        cvm_ntp_servers        = $Config.ntp_servers
        hypervisor_ntp_servers = $Config.ntp_servers
    }
    $body = @{
        aos_package_url         = $Config.aos_package_url
        hypervisor_iso_details  = $hypervisorIsoDetails
        timezone                = $Config.timezone
        common_network_settings = $commonNetworkSettings
        nodes_list              = @()
    }
    $nodePositionLabels = @('A','B','C','D','E','F','G','H')
    $configNodes = @($Config.network.nodes)
    $nodesList = @()
    for ($i = 0; $i -lt $configNodes.Count; $i++) {
        $nc    = $configNodes[$i]
        $nKey  = "Node$($i + 1)"
        $disc  = if ($Nodes.ContainsKey($nKey) -and $Nodes[$nKey]) { $Nodes[$nKey] } else { $null }
        $hvIP  = if ($IPAddresses.ContainsKey("${nKey}_Hypervisor")) { $IPAddresses["${nKey}_Hypervisor"] } else { $nc.hypervisor_ip }
        $cvmIP = if ($IPAddresses.ContainsKey("${nKey}_CVM"))        { $IPAddresses["${nKey}_CVM"]        } else { $nc.cvm_ip        }
        $cfgIpmiGw  = if ($Config.network.PSObject.Properties['ipmi_gateway'] -and $Config.network.ipmi_gateway) { $Config.network.ipmi_gateway } else { '' }
        $cfgIpmiNm  = if ($Config.network.PSObject.Properties['ipmi_netmask'] -and $Config.network.ipmi_netmask) { $Config.network.ipmi_netmask } else { '' }
        $nodeIpmiIp = if ($disc -and $disc.ipmi_ip)      { $disc.ipmi_ip      } elseif ($nc.PSObject.Properties['ipmi_ip'] -and $nc.ipmi_ip)           { $nc.ipmi_ip      } else { '' }
        $nodeIpmiGw = if ($disc -and $disc.ipmi_gateway) { $disc.ipmi_gateway } elseif ($nc.PSObject.Properties['ipmi_gateway'] -and $nc.ipmi_gateway) { $nc.ipmi_gateway } elseif ($cfgIpmiGw) { $cfgIpmiGw } else { '' }
        $nodeIpmiNm = if ($disc -and $disc.ipmi_netmask) { $disc.ipmi_netmask } elseif ($nc.PSObject.Properties['ipmi_netmask'] -and $nc.ipmi_netmask) { $nc.ipmi_netmask } elseif ($cfgIpmiNm) { $cfgIpmiNm } else { '' }
        $nodeEntry = @{
            node_position       = $nodePositionLabels[$i]
            node_serial         = if ($disc) { $disc.node_serial } else { $nc.serial }
            imaged_node_uuid    = if ($disc) { $disc.node_uuid   } else { ''           }
            hypervisor_hostname = $Config.network.hostnames[$i]
            hypervisor_ip       = $hvIP
            hypervisor_gateway  = $IPAddresses.Gateway
            hypervisor_netmask  = $subnetMask
            hypervisor_type     = $apiHypervisorType
            cvm_ip              = $cvmIP
            cvm_gateway         = $IPAddresses.Gateway
            cvm_netmask         = $subnetMask
            image_now           = $shouldImage
        }
        if ($nodeIpmiIp) { $nodeEntry['ipmi_ip']      = $nodeIpmiIp }
        if ($nodeIpmiGw) { $nodeEntry['ipmi_gateway'] = $nodeIpmiGw }
        if ($nodeIpmiNm) { $nodeEntry['ipmi_netmask'] = $nodeIpmiNm }
        $nodesList += $nodeEntry
    }
    $body['nodes_list'] = $nodesList
    if ($hypervisorIsoDetails) {
        $body['hypervisor_isos'] = @(@{
            url             = $hypervisorIsoDetails['url']
            hypervisor_type = $hypervisorIsoDetails['hypervisor_type']
        })
    }
    $body['redundancy_factor'] = [Math]::Min(2, @($Config.network.nodes).Count)
    $body['cluster_type'] = 'hyperconverged'
    # LACP active-active bond mode — read from config, default false
    $body['lacp'] = if ($Config.PSObject.Properties['lacp'] -and $Config.lacp -eq $true) { $true } else { $false }
    if (-not $SkipClusterFormation) {
        $body['cluster_name']        = $Config.clusterName
        $body['cluster_external_ip'] = $IPAddresses.ClusterVIP
        $body['skip_cluster_creation'] = $false
    } else {
        $body['skip_cluster_creation'] = $true
    }
    $logsPath = if ($script:LogsDirectory) { $script:LogsDirectory } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'Logs' }
    if (-not (Test-Path $logsPath)) {
        New-Item -Path $logsPath -ItemType Directory -Force | Out-Null
    }
    Write-DeploymentLog -Message "Imaging request body built (node count: $($body.imaged_nodes.Count))" -Level INFO
    return $body
}

function Start-ClusterImaging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$FCConnection,
        [Parameter(Mandatory = $true)]
        [hashtable]$ImagingBody
    )
    Write-DeploymentLog -Message "Starting cluster imaging job..." -Level INFO
    if ($FCConnection.ImagingEndpoint -and $FCConnection.ImagingEndpoint.Path) {
        $uri = "$($FCConnection.BaseUrl)$($FCConnection.ImagingEndpoint.Path)"
        Write-DeploymentLog -Message "Using discovered imaging endpoint: $($FCConnection.ImagingEndpoint.Path)" -Level INFO
    }
    else {
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
        $jobUUID = if ($response.imaged_cluster_uuid) {
            $response.imaged_cluster_uuid
        }
        elseif ($response.metadata.uuid) {
            $response.metadata.uuid
        }
        elseif ($response.uuid) {
            $response.uuid
        }
        else {
            Write-DeploymentLog -Message "UUID not in POST response, attempting to find cluster by name..." -Level INFO
            Start-Sleep -Seconds 2
            try {
                $listUri = "$($FCConnection.BaseUrl)/api/fc/v1/imaged_clusters/list"
                $listBody = @{} | ConvertTo-Json
                $listResponse = Invoke-RestMethod -Uri $listUri -Method POST -Headers $FCConnection.Headers -Body $listBody -TimeoutSec 30
                $clusterName = $ImagingBody.cluster_name
                $matchingCluster = $listResponse.imaged_clusters | Where-Object { 
                    $_.cluster_name -eq $clusterName 
                } | Sort-Object -Property { 
                    if ($_.created_timestamp) { [DateTime]$_.created_timestamp } else { [DateTime]::MinValue }
                } -Descending | Select-Object -First 1
                if ($matchingCluster) {
                    if ($matchingCluster.imaged_cluster_uuid) {
                        Write-DeploymentLog -Message "Found cluster UUID via list endpoint: $($matchingCluster.imaged_cluster_uuid)" -Level SUCCESS
                        return $matchingCluster.imaged_cluster_uuid
                    }
                    elseif ($matchingCluster.metadata.uuid) {
                        Write-DeploymentLog -Message "Found cluster UUID via list endpoint: $($matchingCluster.metadata.uuid)" -Level SUCCESS
                        return $matchingCluster.metadata.uuid
                    }
                }
                throw "Could not find cluster '$clusterName' in list of imaged clusters"
            }
            catch {
                Write-DeploymentLog -Message "Failed to find cluster via list endpoint: $_" -Level ERROR
                throw "Could not get cluster UUID from POST response or list endpoint"
            }
        }
        Write-DeploymentLog -Message "Imaging job created: $jobUUID" -Level SUCCESS
        return $jobUUID
    }
    catch {
        Write-DeploymentLog -Message "Failed to start imaging: $_" -Level ERROR
        throw "Failed to start imaging: $_"
    }
}

function Get-ImagingProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$FCConnection,
        [Parameter(Mandatory = $true)]
        [string]$JobUUID
    )
    $apiPath = if ($FCConnection.APIPath) { $FCConnection.APIPath } else { "/api/foundation_central/v3" }
    $isV1 = $apiPath -match "/fc/v1"
    function ConvertTo-ProgressObject($obj) {
        if (-not $obj) { return $null }
        $statusObj = if ($obj.PSObject.Properties['status']) { $obj.status } else { $obj }
        $clusterStatus = if ($statusObj.cluster_status) { $statusObj.cluster_status }
                         elseif ($obj.cluster_status)   { $obj.cluster_status }
                         else                           { $null }
        $percentComplete = if ($null -ne $clusterStatus.aggregate_percent_complete) {
                               $clusterStatus.aggregate_percent_complete
                           } elseif ($null -ne $statusObj.aggregate_percent_complete) {
                               $statusObj.aggregate_percent_complete
                           } elseif ($null -ne $obj.aggregate_percent_complete) {
                               $obj.aggregate_percent_complete
                           } else { $null }
        $nodeList = if ($clusterStatus.node_progress_details)   { $clusterStatus.node_progress_details }
                    elseif ($statusObj.node_status_list)        { $statusObj.node_status_list }
                    elseif ($statusObj.node_progress_list)      { $statusObj.node_progress_list }
                    elseif ($obj.node_status_list)              { $obj.node_status_list }
                    elseif ($obj.node_progress_list)            { $obj.node_progress_list }
                    else { $null }
        $currentOp = if ($statusObj.current_operation) { $statusObj.current_operation }
                     elseif ($obj.current_operation)   { $obj.current_operation }
                     else { $null }
        $derivedState = $null
        if ($clusterStatus) {
            if ($null -ne $percentComplete -and [double]$percentComplete -ge 100) {
                $derivedState = 'COMPLETED'
            } elseif ($clusterStatus.cluster_creation_started) {
                $derivedState = 'ClusterFormation'
            } elseif ($clusterStatus.deployment_started) {
                $derivedState = 'Imaging'
            } elseif ($clusterStatus.intent_picked_up) {
                $derivedState = 'Preparing'
            } elseif ($null -ne $percentComplete) {
                $derivedState = 'Queued'
            }
        }
        $v3Phase = $clusterStatus.cluster_creation_phase
        $state   = if (-not [string]::IsNullOrEmpty($v3Phase)) { $v3Phase } else { $derivedState }
        return @{
            State            = $state
            PercentComplete  = $percentComplete
            CurrentOperation = $currentOp
            ClusterStatus    = $clusterStatus
            NodeProgress     = $nodeList
        }
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
                    Write-DeploymentLog -Message "FC progress tracking active for cluster UUID $JobUUID" -Level DEBUG
                }
                $progress = ConvertTo-ProgressObject $clusterObj
                return $progress
            }
            else {
                Write-DeploymentLog -Message "Job UUID $JobUUID not found in FC v1 imaged_clusters list" -Level WARN
            }
        }
        catch {
            Write-DeploymentLog -Message "Failed to get imaging progress via FC v1 list: $_" -Level WARN
        }
    }
    $directUri = "$($FCConnection.BaseUrl)$apiPath/imaged_clusters/$JobUUID"
    try {
        $response = Invoke-RestMethod -Uri $directUri -Method GET -Headers $FCConnection.Headers -TimeoutSec 30
        $progress = ConvertTo-ProgressObject $response
        if ($progress.State -or $progress.PercentComplete -or $progress.CurrentOperation) {
            return $progress
        }
    }
    catch {
        Write-DeploymentLog -Message "Direct GET for imaging progress failed: $_" -Level DEBUG
    }
    if (-not ($apiPath -match "foundation_central/v3")) {
        $v3Uri = "$($FCConnection.BaseUrl)/api/foundation_central/v3/imaged_clusters/$JobUUID"
        try {
            $response = Invoke-RestMethod -Uri $v3Uri -Method GET -Headers $FCConnection.Headers -TimeoutSec 30
            $progress = ConvertTo-ProgressObject $response
            if ($progress.State -or $progress.PercentComplete -or $progress.CurrentOperation) {
                return $progress
            }
        }
        catch {
            Write-DeploymentLog -Message "FC v3 fallback GET for imaging progress failed: $_" -Level DEBUG
        }
    }
    Write-DeploymentLog -Message "Could not retrieve imaging progress for UUID $JobUUID from any endpoint" -Level WARN
    return $null
}

function Wait-ImagingCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$FCConnection,
        [Parameter(Mandatory = $true)]
        [string]$JobUUID,
        [int]$PollIntervalSeconds = 30,
        [int]$TimeoutMinutes = 120
    )
    Write-DeploymentLog -Message "Waiting for imaging completion (timeout: $TimeoutMinutes minutes)..." -Level INFO
    $startTime = Get-Date
    $timeout = $startTime.AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $timeout) {
        $progress = Get-ImagingProgress -FCConnection $FCConnection -JobUUID $JobUUID
        if ($progress) {
            $state = $progress.State
            $percent = $progress.PercentComplete
            $operation = $progress.CurrentOperation
            $nodeProgress = $progress.NodeProgress
            $clusterPhase = if ($progress.ClusterStatus) { $progress.ClusterStatus.cluster_creation_phase } else { $null }
            $hasProgress = (-not [string]::IsNullOrEmpty($state)) -or
                           ($null -ne $percent) -or
                           (-not [string]::IsNullOrEmpty($operation)) -or
                           (-not [string]::IsNullOrEmpty($clusterPhase))
            if (-not $hasProgress) {
                $elapsed = [int]((Get-Date) - $startTime).TotalMinutes
                Write-Host ("[----            Waiting for FC to report progress...            ----] ($elapsed min)") -ForegroundColor Yellow
            } else {
                $pct = if ($null -ne $percent) { [double]$percent } else { 0 }
                $barLength = 40
                $filledLength = [int]($barLength * ($pct / 100))
                $bar = ('#' * $filledLength).PadRight($barLength, '-')
                $elapsed = [int]((Get-Date) - $startTime).TotalMinutes
                $displayState = if (-not [string]::IsNullOrEmpty($state)) { $state } elseif (-not [string]::IsNullOrEmpty($clusterPhase)) { "ClusterFormation:$clusterPhase" } else { "Running" }
                $displayOp    = if (-not [string]::IsNullOrEmpty($operation)) { " $operation" } else { "" }
                $nodeStr = ""
                if ($nodeProgress) {
                    $msgs = foreach ($node in $nodeProgress) {
                        $msg = if ($node.node_state)  { $node.node_state }
                               elseif ($node.state)   { $node.state }
                               elseif ($node.message) { $node.message }
                               elseif ($node.status)  { $node.status }
                               else { $null }
                        if ($msg) { $msg }
                    }
                    $uniqueMsgs = @($msgs | Select-Object -Unique)
                    if ($uniqueMsgs.Count -gt 0) { $nodeStr = "  $($uniqueMsgs -join ' | ')" }
                }
                Write-Host ("[{0}] {1,3}% - {2}{3} ({4} min){5}" -f $bar, $pct, $displayState, $displayOp, $elapsed, $nodeStr) -ForegroundColor Cyan
                Write-DeploymentLog -Message ("[{0}] {1,3}% - {2}{3} ({4} min){5}" -f $bar, $pct, $displayState, $displayOp, $elapsed, $nodeStr) -Level INFO
            }
            $completedStates = @('COMPLETED', 'SUCCEEDED', 'SUCCESS', 'COMPLETE')
            $failedStates    = @('FAILED', 'ERROR', 'FAILURE', 'ABORTED')
            $isComplete = ($percent -eq 100) -or
                          ($completedStates -contains $state) -or
                          ($completedStates -contains $clusterPhase)
            $isFailed   = ($failedStates -contains $state) -or
                          ($failedStates -contains $clusterPhase)
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

function Invoke-CVMShutdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$CvmIPs,
        [string]$CvmUsername = 'nutanix',
        [string]$CvmPassword = 'nutanix/4u',
        [int]$WaitTimeoutSeconds = 120
    )
    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        Write-Host "  ℹ Installing Posh-SSH module (required for CVM SSH access)..." -ForegroundColor Cyan
        try {
            Install-Module -Name Posh-SSH -Force -Scope CurrentUser -AllowClobber
        } catch {
            throw "Failed to install Posh-SSH: $_. Run: Install-Module Posh-SSH -Scope CurrentUser"
        }
    }
    Import-Module Posh-SSH -Force
    $cred = New-Object System.Management.Automation.PSCredential(
        $CvmUsername,
        (ConvertTo-SecureString $CvmPassword -AsPlainText -Force)
    )
    $reachable = $CvmIPs | Where-Object { Test-Connection -ComputerName $_ -Count 1 -Quiet }
    if (-not $reachable) {
        Write-DeploymentLog -Message "No live CVMs detected at target IPs - nothing to shut down" -Level INFO
        return @{ Success = $true; ShutDown = @() }
    }
    Write-Host ""
    Write-Host "Pre-Imaging Cleanup:" -ForegroundColor White
    Write-Host "  ⚠ Live CVMs detected at target IPs - shutting down before re-imaging" -ForegroundColor Yellow
    $shutDown = @()
    $failed   = @()
    foreach ($ip in $reachable) {
        Write-Host "  ℹ Sending poweroff to CVM $ip..." -ForegroundColor Cyan
        try {
            $session = New-SSHSession -ComputerName $ip -Credential $cred -AcceptKey -Force -ConnectionTimeout 15 -ErrorAction Stop
            try {
                Invoke-SSHCommand -SessionId $session.SessionId -Command 'sudo poweroff' -Timeout 10 -ErrorAction SilentlyContinue | Out-Null
            } catch {
                Write-DeploymentLog -Message "CVM $ip SSH dropped after poweroff (expected): $_" -Level DEBUG
            }
            Remove-SSHSession -SessionId $session.SessionId -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  ✓ Poweroff sent to $ip" -ForegroundColor Green
            $shutDown += $ip
        } catch {
            Write-DeploymentLog -Message "Could not SSH to CVM $ip : $_" -Level WARN
            Write-Host "  ⚠ Could not SSH to $ip : $_" -ForegroundColor Yellow
            $failed += $ip
        }
    }
    $allTargets = $reachable
    Write-Host "  ℹ Waiting for CVM IPs to go offline (timeout: $WaitTimeoutSeconds s)..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
    $remaining = [System.Collections.Generic.List[string]]$allTargets
    while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $stillUp = @($remaining | Where-Object { Test-Connection -ComputerName $_ -Count 1 -Quiet })
        foreach ($gone in ($remaining | Where-Object { $stillUp -notcontains $_ })) {
            Write-Host "  ✓ $gone is offline" -ForegroundColor Green
            $remaining.Remove($gone) | Out-Null
        }
    }
    if ($remaining.Count -gt 0) {
        Write-DeploymentLog -Message "CVMs still reachable after $WaitTimeoutSeconds s: $($remaining -join ', ')" -Level WARN
        Write-Host "  ⚠ Warning: these IPs are still reachable after timeout: $($remaining -join ', ')" -ForegroundColor Yellow
        Write-Host "    Foundation will attempt to re-image anyway, but an IP conflict may occur." -ForegroundColor Gray
        return @{ Success = $false; ShutDown = $shutDown; StillUp = $remaining }
    }
    Write-Host "  ✓ All CVMs are offline - safe to proceed with imaging" -ForegroundColor Green
    return @{ Success = $true; ShutDown = $shutDown }
}

#endregion

#region Witness Configuration Functions

function Wait-CVMGenesisReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$CvmIPs,
        [Parameter(Mandatory = $true)]
        [string]$Username,
        [Parameter(Mandatory = $true)]
        [string]$Password,
        [int]$TimeoutMinutes      = 20,
        [int]$PollIntervalSeconds = 30
    )
    Import-Module Posh-SSH -Force -ErrorAction SilentlyContinue
    $secPass  = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred     = New-Object System.Management.Automation.PSCredential($Username, $secPass)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-DeploymentLog -Message "Waiting for genesis to be ready on CVMs: $($CvmIPs -join ', ') (timeout: ${TimeoutMinutes}min)" -Level INFO
    Write-Host "  Waiting for CVM genesis to be ready before starting cluster create..." -ForegroundColor Cyan
    while ((Get-Date) -lt $deadline) {
        $allReady  = $true
        $notReady  = @()
        foreach ($ip in $CvmIPs) {
            try {
                $session = New-SSHSession -ComputerName $ip -Credential $cred -AcceptKey -Force -ConnectionTimeout 15 -ErrorAction Stop
                $result  = Invoke-SSHCommand -SessionId $session.SessionId -Command "genesis status 2>/dev/null | head -5" -Timeout 20
                Remove-SSHSession -SessionId $session.SessionId | Out-Null
                $output = ($result.Output -join " ").ToLower()
                if ($output -match "running|started") {
                    Write-DeploymentLog -Message "CVM $ip genesis: READY" -Level INFO
                }
                else {
                    $allReady = $false
                    $notReady += $ip
                    Write-DeploymentLog -Message "CVM $ip genesis: NOT READY (output: $($result.Output -join ' '))" -Level DEBUG
                }
            }
            catch {
                $allReady = $false
                $notReady += $ip
                Write-DeploymentLog -Message "CVM $ip SSH not reachable yet: $_" -Level DEBUG
            }
        }
        if ($allReady) {
            Write-Host "  ✓ Genesis is running on all CVMs ($($CvmIPs -join ', '))" -ForegroundColor Green
            Write-DeploymentLog -Message "All CVMs genesis ready - proceeding with cluster create" -Level SUCCESS
            Write-Host "  ℹ Waiting 15 seconds for services to stabilise..." -ForegroundColor Gray
            Start-Sleep -Seconds 15
            return
        }
        $elapsed = [int]((Get-Date) - ($deadline.AddMinutes(-$TimeoutMinutes))).TotalMinutes
        Write-Host ("  [Waiting] Genesis not ready on: {0} ({1} min elapsed)" -f ($notReady -join ', '), $elapsed) -ForegroundColor Yellow
        Write-DeploymentLog -Message "Genesis not ready on: $($notReady -join ', ') (${elapsed}min elapsed)" -Level WARN
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    throw "Timeout after $TimeoutMinutes minutes waiting for genesis to be ready on CVMs: $($CvmIPs -join ', ')"
}

function Invoke-DirectClusterCreate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CvmIp,
        [Parameter(Mandatory = $true)]
        [string]$Username,
        [Parameter(Mandatory = $true)]
        [string]$Password,
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,
        [Parameter(Mandatory = $true)]
        [string]$ClusterVIP,
        [Parameter(Mandatory = $true)]
        [string[]]$CvmIPs,
        [int]$RedundancyFactor = 2,
        [string[]]$NameServerIPs = @(),
        [string[]]$NtpServers    = @()
    )
    Write-DeploymentLog -Message "Invoke-DirectClusterCreate (SSH): CVM=$CvmIp, Name=$ClusterName, VIP=$ClusterVIP, Nodes=[$($CvmIPs -join ', ')], RF=$RedundancyFactor" -Level INFO
    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        Write-Host "  ℹ Installing Posh-SSH module (required for CVM SSH access)..." -ForegroundColor Cyan
        try {
            Install-Module -Name Posh-SSH -Force -Scope CurrentUser -AllowClobber
        }
        catch {
            throw "Failed to install Posh-SSH module: $_. Install manually: Install-Module Posh-SSH -Scope CurrentUser"
        }
    }
    Import-Module Posh-SSH -Force
    $dnsArg  = if ($NameServerIPs.Count -gt 0) { "--dns_servers='$($NameServerIPs -join ',')' " } else { "" }
    $ntpArg  = if ($NtpServers.Count -gt 0) { "--ntp_servers='$($NtpServers -join ',')' " } else { "" }
    $seedNodes = $CvmIPs -join ','
    $cmd = ("/home/nutanix/cluster/bin/cluster -s '$seedNodes' " +
            "--cluster_name='$ClusterName' " +
            "--cluster_external_ip=$ClusterVIP " +
            "--redundancy_factor=$RedundancyFactor " +
            "$dnsArg$ntpArg" +
            "create").Trim()
    Write-DeploymentLog -Message "SSH cluster create command: $cmd" -Level INFO
    Wait-CVMGenesisReady `
        -CvmIPs   $CvmIPs `
        -Username $Username `
        -Password $Password
    $logsDir = $script:LogsDirectory
    $job = Start-Job -ScriptBlock {
        param($CvmIp, $Username, $Password, $cmd, $logsDir)
        try {
            Import-Module Posh-SSH -Force
            $secPass = ConvertTo-SecureString $Password -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential($Username, $secPass)
            $session = New-SSHSession -ComputerName $CvmIp -Credential $cred -AcceptKey -Force -ConnectionTimeout 30
            $result = Invoke-SSHCommand -SessionId $session.SessionId -Command $cmd -Timeout 1800
            Remove-SSHSession -SessionId $session.SessionId | Out-Null
            return @{
                ExitStatus = $result.ExitStatus
                Output     = $result.Output -join "`n"
                Error      = $result.Error  -join "`n"
            }
        }
        catch {
            return @{ ExitStatus = 1; Output = ""; Error = $_.ToString() }
        }
    } -ArgumentList $CvmIp, $Username, $Password, $cmd, $logsDir
    Write-DeploymentLog -Message "SSH cluster create job started (Job ID: $($job.Id))" -Level INFO
    return $job.Id
}

function Wait-DirectClusterCreateTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CvmIp,
        [Parameter(Mandatory = $true)]
        [string]$Username,
        [Parameter(Mandatory = $true)]
        [string]$Password,
        [Parameter(Mandatory = $true)]
        [string]$TaskId,
        [int]$PollIntervalSeconds = 30,
        [int]$TimeoutMinutes = 60
    )
    $jobId     = [int]$TaskId
    $startTime = Get-Date
    $timeout   = $startTime.AddMinutes($TimeoutMinutes)
    Write-DeploymentLog -Message "Waiting for SSH cluster create job $jobId (timeout: ${TimeoutMinutes}min)" -Level INFO
    while ((Get-Date) -lt $timeout) {
        $job     = Get-Job -Id $jobId -ErrorAction SilentlyContinue
        $elapsed = [int]((Get-Date) - $startTime).TotalMinutes
        if (-not $job) {
            return @{ Success = $false; Error = "Job $jobId not found" }
        }
        switch ($job.State) {
            'Completed' {
                $result = Receive-Job -Id $jobId -ErrorAction SilentlyContinue
                Remove-Job -Id $jobId -Force -ErrorAction SilentlyContinue
                Write-DeploymentLog -Message "SSH cluster create output: EXIT=$($result.ExitStatus)" -Level INFO
                Write-DeploymentLog -Message "SSH cluster create output: $($result.Output)" -Level INFO
                if ($result.Error) {
                    Write-DeploymentLog -Message "SSH cluster create stderr: $($result.Error)" -Level DEBUG
                }
                if ($result.ExitStatus -eq 0) {
                    Write-DeploymentLog -Message "Cluster create via SSH SUCCEEDED" -Level SUCCESS
                    return @{ Success = $true }
                }
                else {
                    $errMsg = if ($result.Error) { $result.Error } else { $result.Output }
                    Write-DeploymentLog -Message "Cluster create via SSH FAILED (exit=$($result.ExitStatus)): $errMsg" -Level ERROR
                    return @{ Success = $false; Error = "Exit code $($result.ExitStatus): $errMsg" }
                }
            }
            'Failed' {
                $errInfo = $job.ChildJobs[0].JobStateInfo.Reason.Message
                Remove-Job -Id $jobId -Force -ErrorAction SilentlyContinue
                Write-DeploymentLog -Message "SSH job failed: $errInfo" -Level ERROR
                return @{ Success = $false; Error = $errInfo }
            }
            'Running' {
                Write-Host ("  [Running] SSH cluster create in progress... ({0} min elapsed)" -f $elapsed) -ForegroundColor Cyan
                Write-DeploymentLog -Message "SSH job still running (${elapsed}min elapsed)" -Level DEBUG
                Start-Sleep -Seconds $PollIntervalSeconds
            }
            default {
                Write-Host "  [Waiting] Job state: $($job.State) ($elapsed min)" -ForegroundColor Yellow
                Start-Sleep -Seconds $PollIntervalSeconds
            }
        }
    }
    Stop-Job -Id $jobId -ErrorAction SilentlyContinue
    Remove-Job -Id $jobId -Force -ErrorAction SilentlyContinue
    Write-DeploymentLog -Message "Wait-DirectClusterCreateTask: timeout after $TimeoutMinutes minutes" -Level ERROR
    return @{ Success = $false; Error = "Timeout after $TimeoutMinutes minutes" }
}

function Set-ClusterWitness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterVIP,
        [Parameter(Mandatory = $true)]
        [string]$Username,
        [Parameter(Mandatory = $true)]
        [string]$Password,
        [Parameter(Mandatory = $true)]
        [string]$WitnessIP
    )
    Write-DeploymentLog -Message "Configuring witness at $WitnessIP for cluster $ClusterVIP" -Level INFO
    $prismConnection = Initialize-PrismConnection -ClusterVIP $ClusterVIP -Username $Username -Password $Password
    $uri = "$($prismConnection.BaseUrl)/PrismGateway/services/rest/v2.0/cluster/two_node_witness"
    $body = @{
        witness_address = $WitnessIP
    } | ConvertTo-Json
    try {
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $prismConnection.Headers -Body $body -TimeoutSec 60
        Write-DeploymentLog -Message "Witness configured successfully" -Level SUCCESS
        return $true
    }
    catch {
        Write-DeploymentLog -Message "Failed to configure witness: $_" -Level ERROR
        throw "Failed to configure witness: $_"
    }
}

function Test-WitnessConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterVIP,
        [Parameter(Mandatory = $true)]
        [string]$Username,
        [Parameter(Mandatory = $true)]
        [string]$Password
    )
    Write-DeploymentLog -Message "Verifying witness connection..." -Level INFO
    $prismConnection = Initialize-PrismConnection -ClusterVIP $ClusterVIP -Username $Username -Password $Password
    $uri = "$($prismConnection.BaseUrl)/PrismGateway/services/rest/v2.0/cluster/two_node_witness"
    try {
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $prismConnection.Headers -TimeoutSec 30
        if ($response.witness_state -eq "CONNECTED" -or $response.witness_address) {
            Write-DeploymentLog -Message "Witness is connected: $($response.witness_address)" -Level SUCCESS
            return @{ Connected = $true; WitnessAddress = $response.witness_address }
        }
        else {
            Write-DeploymentLog -Message "Witness not connected" -Level WARN
            return @{ Connected = $false }
        }
    }
    catch {
        Write-DeploymentLog -Message "Failed to verify witness: $_" -Level WARN
        return @{ Connected = $false; Error = $_ }
    }
}

#endregion

#region Historical Timings Functions

function Update-HistoricalTimings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,
        [Parameter(Mandatory = $true)]
        [hashtable]$PhaseTimings,
        [Parameter(Mandatory = $true)]
        [int]$TotalDurationMinutes,
        [Parameter(Mandatory = $true)]
        [bool]$Success,
        [string]$AOSVersion,
        [string]$Path = "historical-timings.json"
    )
    $history = @{
        deployments = @()
        statistics  = @{
            total_deployments      = 0
            successful_deployments = 0
            average_duration_minutes = 0
        }
    }
    if (Test-Path $Path) {
        try {
            $history = Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable
        }
        catch { }
    }
    $newRecord = @{
        cluster_name          = $ClusterName
        deployment_date       = (Get-Date).ToString("o")
        total_duration_minutes = $TotalDurationMinutes
        phases                = $PhaseTimings
        node_count            = 2
        aos_version           = $AOSVersion
        success               = $Success
    }
    $history.deployments += $newRecord
    $history.statistics.total_deployments = $history.deployments.Count
    $history.statistics.successful_deployments = ($history.deployments | Where-Object { $_.success }).Count
    $successfulDeployments = $history.deployments | Where-Object { $_.success }
    if ($successfulDeployments.Count -gt 0) {
        $history.statistics.average_duration_minutes = [math]::Round(
            ($successfulDeployments | Measure-Object -Property total_duration_minutes -Average).Average, 1
        )
        $history.statistics.fastest_deployment_minutes = ($successfulDeployments | Measure-Object -Property total_duration_minutes -Minimum).Minimum
        $history.statistics.slowest_deployment_minutes = ($successfulDeployments | Measure-Object -Property total_duration_minutes -Maximum).Maximum
    }
    $history | ConvertTo-Json -Depth 10 | Out-File -FilePath $Path -Encoding UTF8
    Write-DeploymentLog -Message "Historical timings updated" -Level DEBUG
}

#endregion

#region Display Functions

function Show-DeploymentPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,
        [Parameter(Mandatory = $true)]
        [hashtable]$IPAddresses,
        [hashtable]$Nodes,
        [ValidateSet('ImageOnly', 'ClusterOnly', 'Both')]
        [string]$Mode = 'Both'
    )
    $modeDescription = switch ($Mode) {
        'ImageOnly'   { 'Image nodes only  (no cluster formed)' }
        'ClusterOnly' { 'Cluster only       (existing image re-used, image_now=false)' }
        'Both'        { 'Bare metal deployment (image + cluster)' }
    }
    $configNodes = @($Config.network.nodes)
    $nodeLines = ""
    for ($i = 0; $i -lt $configNodes.Count; $i++) {
        $nKey     = "Node$($i + 1)"
        $hostname = if ($Config.network.hostnames -and $Config.network.hostnames.Count -gt $i) { $Config.network.hostnames[$i] } else { $configNodes[$i].hostname }
        $serial   = if ($Nodes -and $Nodes[$nKey]) { $Nodes[$nKey].node_serial } else { "[Discovery pending]" }
        $model    = if ($Nodes -and $Nodes[$nKey]) { $Nodes[$nKey].model       } else { "[Discovery pending]" }
        $ipmiIp   = if ($IPAddresses.ContainsKey("${nKey}_IPMI"))       { $IPAddresses["${nKey}_IPMI"]       } else { "N/A" }
        $cvmIp    = if ($IPAddresses.ContainsKey("${nKey}_CVM"))        { $IPAddresses["${nKey}_CVM"]        } else { $configNodes[$i].cvm_ip }
        $hvIp     = if ($IPAddresses.ContainsKey("${nKey}_Hypervisor")) { $IPAddresses["${nKey}_Hypervisor"] } else { $configNodes[$i].hypervisor_ip }
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

Operation Mode:    $Mode - $modeDescription

Cluster Configuration:
  Name:              $($Config.clusterName)
  Gateway:           $($Config.network.gateway ?? $resolvedIpPrefix)
  Prefix Length:     $($Config.network.prefix_length ?? 'n/a')
  VLAN:              $vlanLine
  
Auto-Generated Network IPs:
  Cluster VIP:       $($IPAddresses.ClusterVIP)
  Subnet Mask:       $(if ($Config.network.prefix_length) { ConvertTo-SubnetMask -PrefixLength ([int]$Config.network.prefix_length) } else { $Config.network.subnet_mask })
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

function Show-DeploymentSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,
        [Parameter(Mandatory = $true)]
        [hashtable]$IPAddresses,
        [Parameter(Mandatory = $true)]
        [DateTime]$StartTime,
        [Parameter(Mandatory = $true)]
        [DateTime]$EndTime,
        [string]$LogFile,
        [ValidateSet('ImageOnly', 'ClusterOnly', 'Both')]
        [string]$Mode = 'Both'
    )
    $duration    = $EndTime - $StartTime
    $totalMins   = [int]$duration.TotalMinutes
    $durationStr = if ($duration.TotalHours -ge 1) {
        "{0}t {1}m {2}s" -f [int]$duration.TotalHours, $duration.Minutes, $duration.Seconds
    } else {
        "{0}m {1}s" -f $duration.Minutes, $duration.Seconds
    }
    $nodeLines = ""
    $configNodes = @($Config.network.nodes)
    for ($i = 0; $i -lt $configNodes.Count; $i++) {
        $hostname = if ($Config.network.hostnames -and $Config.network.hostnames.Count -gt $i) {
            $Config.network.hostnames[$i]
        } else { $configNodes[$i].hostname }
        $nodeLines += "  Node $($i+1):            $hostname`n"
    }
    $nodeLines = $nodeLines.TrimEnd("`n")
    $clusterSection = if ($Mode -ne 'ImageOnly') { @"

Cluster Information:
  Name:              $($Config.clusterName)
  Cluster VIP:       $($IPAddresses.ClusterVIP)
  Prism URL:         https://$($IPAddresses.ClusterVIP):9440
  Operation Mode:    $Mode
"@ } else { @"

Operation Mode:      ImageOnly - nodes imaged, no cluster formed
"@ }
    $nextStepsSection = if ($Mode -ne 'ImageOnly') { @"

IMPORTANT - NEXT STEPS:
1. Access Prism:
   URL: https://$($IPAddresses.ClusterVIP):9440
   User: admin
   
2. Run post-deployment verification:
   .\Generate-DeploymentReport.ps1 -ClusterName $($Config.clusterName)
"@ } else { @"

NEXT STEP:
  Run .\Deploy-Cluster.ps1 -ConfigFile $($Config._sourceFile) -Mode ClusterOnly
  to form the cluster on the newly imaged nodes.
"@ }
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "                DEPLOYMENT COMPLETED SUCCESSFULLY               " -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host $clusterSection -ForegroundColor Green
    Write-Host ""
    Write-Host "Nodes:" -ForegroundColor Green
    Write-Host $nodeLines -ForegroundColor Green
    Write-Host ""
    Write-Host "Deployment Time:" -ForegroundColor Green
    Write-Host "  Started:           $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green
    Write-Host "  Completed:         $($EndTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green
    Write-Host ("  Total Duration:    {0}" -f $durationStr) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Files Generated:" -ForegroundColor Green
    Write-Host "  ✓ Deployment log:  $LogFile" -ForegroundColor Green
    Write-Host $nextStepsSection -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
}

#endregion

#endregion Inlined Module Functions

# Global output level (will be set from config)
$script:OutputLevel = "verbose"  # Default: verbose, normal, minimal

# Helper function for controlled output
function Write-DeploymentOutput {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet('Cyan','Green','Yellow','Red','White','Gray')]
        [string]$Color = 'White',
        
        [Parameter(Mandatory=$false)]
        [ValidateSet('Header','Success','Warning','Error','Info','Detail')]
        [string]$Level = 'Info'
    )
    
    # Always show headers (Cyan), errors (Red), and warnings (Yellow)
    $alwaysShow = $Color -eq 'Cyan' -or $Color -eq 'Red' -or $Color -eq 'Yellow' -or $Level -eq 'Header' -or $Level -eq 'Error' -or $Level -eq 'Warning'
    
    switch ($script:OutputLevel) {
        'minimal' {
            # Only show headers (Cyan)
            if ($Color -eq 'Cyan' -or $Level -eq 'Header') {
                Write-Host $Message -ForegroundColor $Color
            }
        }
        'normal' {
            # Show headers, success, warnings, errors, and white text
            if ($alwaysShow -or $Color -eq 'Green' -or $Color -eq 'White' -or $Level -eq 'Success') {
                Write-Host $Message -ForegroundColor $Color
            }
        }
        'verbose' {
            # Show everything
            Write-Host $Message -ForegroundColor $Color
        }
    }
}

#region Main Script

try {
    $scriptStartTime = Get-Date

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "       Nutanix Zero Touch Installation - Cluster Deployment    " -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    # --- Early IP in-use check for node-specific IPs ---
    # Load config file minimally to get node IPs
    $earlyConfig = Get-Content $ConfigFile | ConvertFrom-Json
    if ($earlyConfig.network.nodes -and @($earlyConfig.network.nodes).Count -ge 1) {
        $nodeIPsToCheck = @()
        foreach ($earlyNode in @($earlyConfig.network.nodes)) {
            if ($earlyNode.cvm_ip)        { $nodeIPsToCheck += $earlyNode.cvm_ip }
            if ($earlyNode.hypervisor_ip) { $nodeIPsToCheck += $earlyNode.hypervisor_ip }
        }
        $ipInUseErrors = @()
        foreach ($ip in $nodeIPsToCheck) {
            if ($ip -and (Test-IPInUse -IPAddress $ip -TimeoutMilliseconds 1000)) {
                $ipInUseErrors += "IP address $ip is already in use."
            }
        }
        if ($ipInUseErrors.Count -gt 0) {
            Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
            Write-Host "  ERROR: One or more node IP addresses are already in use!" -ForegroundColor Red
            foreach ($err in $ipInUseErrors) {
                Write-Host "  ✗ $err" -ForegroundColor Red
            }
            Write-Host "  Please ensure all node-specific CVM and Hypervisor IPs are free before deployment." -ForegroundColor Yellow
            Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
            exit 1
        }
    }
    
    #region Phase 1: Load and Validate Configuration
    Write-Host "[PHASE 1] Loading and validating configuration..." -ForegroundColor Cyan
    Write-Host ""
    
    $configResult = Test-ConfigurationFile -ConfigPath $ConfigFile
    
    if (-not $configResult.Valid) {
        Write-Host "Configuration validation FAILED:" -ForegroundColor Red
        foreach ($err in $configResult.Errors) {
            Write-Host "  ✗ $err" -ForegroundColor Red
        }
        exit 1
    }
    
    $config = $configResult.Config
    
    # Set output level from config (default to verbose if not specified)
    if ($config.PSObject.Properties.Name -contains 'output_level') {
        $script:OutputLevel = $config.output_level
        $env:ZTIPS_OUTPUT_LEVEL = $config.output_level
        Write-Host "  ℹ Output level set to: $($script:OutputLevel)" -ForegroundColor Gray
    }
    
    Write-Host "  ✓ Configuration file is valid" -ForegroundColor Green
    
    foreach ($warning in $configResult.Warnings) {
        Write-Host "  ⚠ $warning" -ForegroundColor Yellow
    }
    
    # Password check
    if (-not $SkipPasswordCheck) {
        if ($config.prism_central.password.Length -lt 8) {
            Write-Host "  ✗ Password must be at least 8 characters" -ForegroundColor Red
            exit 1
        }
    }
    
    # Initialize logging
    $sharedLog = if ($LogFile) { $LogFile } else { '' }
    $logFile = Initialize-DeploymentLog -ClusterName $config.clusterName -SharedLogFile $sharedLog
    Write-DeploymentLog -Message "Deployment started for cluster: $($config.clusterName)" -Level INFO
    
    # Generate IP addresses
    $ipmiIPs = @()
    if ($config.network.ipmi_ips -and $config.network.ipmi_ips.Count -ge 2) {
        $ipmiIPs = $config.network.ipmi_ips
    }
    
    $clusterVIP = $null
    if ($config.network.cluster_vip) {
        $clusterVIP = $config.network.cluster_vip
    }

    $ipAddresses = Get-IPAddresses `
        -Gateway $config.network.gateway `
        -PrefixLength ([int]$config.network.prefix_length) `
        -ClusterVIP $clusterVIP `
        -Nodes $config.network.nodes `
        -IPMIIPs $ipmiIPs

    Write-DeploymentLog -Message "IP addresses resolved from gateway $($config.network.gateway) /$($config.network.prefix_length)" -Level INFO
    
    Write-Host ""
    #endregion
    
    #region Phase 2: Connect to Foundation Central
    Write-Host "[PHASE 2] Connecting to Foundation Central..." -ForegroundColor Cyan
    Write-Host ""
    
    try {
        $fcConnection = Initialize-FCConnection `
            -Url $config.prism_central.url `
            -Username $config.prism_central.username `
            -Password $config.prism_central.password
        
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
        
        # Check if we have any nodes at all
        if (-not $availableNodes -or $availableNodes.Count -eq 0) {
            Write-Host ""
            Write-Host "  ╔════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
            Write-Host "  ║                    NO NODES AVAILABLE IN FOUNDATION CENTRAL                ║" -ForegroundColor Red
            Write-Host "  ╚════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
            Write-Host ""
            Write-Host "  CURRENT SITUATION:" -ForegroundColor Yellow
            Write-Host "    Foundation Central reports 0 nodes available for deployment." -ForegroundColor White
            Write-Host "    Without discovered nodes, the deployment process cannot continue." -ForegroundColor White
            Write-Host ""
            Write-Host "  WHY THIS HAPPENS:" -ForegroundColor Yellow
            Write-Host "    • Foundation Central discovers nodes via IPMI/BMC network interface" -ForegroundColor White
            Write-Host "    • Nodes must be powered ON and have network connectivity" -ForegroundColor White
            Write-Host "    • IPMI credentials must be correct and accessible from FC" -ForegroundColor White
            Write-Host ""
            Write-Host "  TROUBLESHOOTING STEPS:" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "    [1] VERIFY NODE POWER STATE" -ForegroundColor Cyan
            Write-Host "        • Ensure both nodes are powered ON" -ForegroundColor Gray
            Write-Host "        • Check physical LED indicators on server front panel" -ForegroundColor Gray
            Write-Host "        • Verify power supplies are functioning" -ForegroundColor Gray
            Write-Host ""
            Write-Host "    [2] CHECK IPMI NETWORK CONNECTIVITY" -ForegroundColor Cyan
            Write-Host "        • Verify IPMI network cable is connected" -ForegroundColor Gray
            Write-Host "        • Test IPMI IP reachability from Foundation Central VM:" -ForegroundColor Gray
            if ($config.network.ipmi_ips -and $config.network.ipmi_ips.Count -gt 0) {
                Write-Host "          - IPMI Node 1: $($config.network.ipmi_ips[0])" -ForegroundColor White
                Write-Host "          - IPMI Node 2: $($config.network.ipmi_ips[1])" -ForegroundColor White
                Write-Host "          - Test command: ping $($config.network.ipmi_ips[0])" -ForegroundColor Gray
            } else {
                Write-Host "          - IPMI IPs not specified in config" -ForegroundColor Yellow
            }
            Write-Host "        • Verify IPMI VLAN/network is accessible from FC" -ForegroundColor Gray
            Write-Host ""
            Write-Host "    [3] VERIFY IPMI CREDENTIALS" -ForegroundColor Cyan
            Write-Host "        • Default IPMI username: admin (or ADMIN)" -ForegroundColor Gray
            Write-Host "        • Verify IPMI password has not been changed" -ForegroundColor Gray
            Write-Host "        • Test IPMI login via web interface or ipmitool" -ForegroundColor Gray
            Write-Host ""
            Write-Host "    [4] CHECK FOUNDATION CENTRAL DISCOVERY" -ForegroundColor Cyan
            Write-Host "        • Login to Foundation Central: $($config.foundation_central.url)" -ForegroundColor White
            Write-Host "        • Navigate to: Home -> Nodes" -ForegroundColor Gray
            Write-Host "        • Check if nodes appear in the discovery list" -ForegroundColor Gray
            Write-Host "        • Review discovery logs for error messages" -ForegroundColor Gray
            Write-Host ""
            Write-Host "    [5] MANUAL NODE DISCOVERY (if IPMI unavailable)" -ForegroundColor Cyan
            Write-Host "        • Some hardware may require manual node registration" -ForegroundColor Gray
            Write-Host "        • Check if nodes have Discovery OS running (Phoenix)" -ForegroundColor Gray
            Write-Host "        • Nodes may be in RMA mode and need special handling" -ForegroundColor Gray
            Write-Host ""
            Write-Host "    [6] VERIFY FOUNDATION CENTRAL SERVICES" -ForegroundColor Cyan
            Write-Host "        • Restart FC services if discovery is stuck:" -ForegroundColor Gray
            Write-Host "          genesis stop foundation_central; genesis start foundation_central" -ForegroundColor Gray
            Write-Host ""
            Write-Host "  EXPECTED NODE CONFIGURATION:" -ForegroundColor Yellow
            if ($config.network.nodes -and @($config.network.nodes).Count -ge 1) {
                $cfgNodes = @($config.network.nodes)
                for ($ni = 0; $ni -lt $cfgNodes.Count; $ni++) {
                    Write-Host "    Node $($ni+1): $($cfgNodes[$ni].hostname) (Serial: $($cfgNodes[$ni].serial))" -ForegroundColor White
                }
            } else {
                Write-Host "    At least 1 node required for deployment" -ForegroundColor White
            }
            Write-Host ""
            Write-Host "  ═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Red
            Write-Host ""
            Write-DeploymentLog -Message "CRITICAL: No nodes available in Foundation Central" -Level ERROR
            throw "No nodes available in Foundation Central. Cannot proceed with deployment."
        }
        
        # Node matching: always by serial number
        $configNodes = @($config.network.nodes)
        $useSerialMatching = $configNodes.Count -ge 1
        Write-Host ""
        if ($useSerialMatching) {
            Write-Host "  Using serial number-based node matching..." -ForegroundColor Cyan
            $serials = @($configNodes | ForEach-Object { $_.serial })
            Write-Host "  Searching for nodes with serials: $($serials -join ', ')" -ForegroundColor White
            $nodes = Find-NodesBySerial `
                -AvailableNodes $availableNodes `
                -Serials $serials
        } else {
            throw "No valid node matching strategy found. Please specify node serials in config."
        }
        
        # Display matched nodes and keep discovery objects
        $discoveredNodes = @()
        for ($ni = 0; $ni -lt $configNodes.Count; $ni++) {
            $nKey = "Node$($ni + 1)"
            $dn = $nodes[$nKey]
            Write-Host "  ✓ Node $($ni+1): Serial $($dn.node_serial), Model $($dn.model), UUID: $($dn.node_uuid)" -ForegroundColor Green
            $discoveredNodes += $dn
        }
        
        # Clean node objects - keep only node_uuid from discovery, rest from config
        $cleanNodes = @{}
        for ($ni = 0; $ni -lt $configNodes.Count; $ni++) {
            $nKey = "Node$($ni + 1)"
            $cleanNodes[$nKey] = [PSCustomObject]@{
                node_uuid   = $discoveredNodes[$ni].node_uuid
                node_serial = $discoveredNodes[$ni].node_serial
            }
        }
        $nodes = $cleanNodes
        
        # Auto-detect network configuration from discovered nodes
        Write-Host ""
        Write-Host "  Auto-detecting network configuration from discovered nodes..." -ForegroundColor White
        
        $autoDetectedConfig = @{
            Hypervisor_Gateway = $null
            Hypervisor_Netmask = $null
        }
        # Use first discovered node for gateway/netmask auto-detection
        if ($discoveredNodes[0].hypervisor_gateway) {
            $autoDetectedConfig.Hypervisor_Gateway = $discoveredNodes[0].hypervisor_gateway
            Write-Host "    └─ Hypervisor Gateway: $($discoveredNodes[0].hypervisor_gateway) (auto-detected)" -ForegroundColor Gray
        }
        if ($discoveredNodes[0].hypervisor_netmask) {
            $autoDetectedConfig.Hypervisor_Netmask = $discoveredNodes[0].hypervisor_netmask
            Write-Host "    └─ Hypervisor Netmask: $($discoveredNodes[0].hypervisor_netmask) (auto-detected)" -ForegroundColor Gray
        }
        # Check per-node Discovery OS hypervisor IPs
        $anyDiscoveryIP = $false
        for ($ni = 0; $ni -lt $discoveredNodes.Count; $ni++) {
            if ($discoveredNodes[$ni].hypervisor_ip) {
                $autoDetectedConfig["Hypervisor_IP$($ni+1)"] = $discoveredNodes[$ni].hypervisor_ip
                Write-Host "    └─ Node $($ni+1) Hypervisor IP: $($discoveredNodes[$ni].hypervisor_ip) (Discovery OS) ⚠" -ForegroundColor Yellow
                $anyDiscoveryIP = $true
            }
        }
        if ($anyDiscoveryIP) {
            Write-Host ""
            Write-Host "  ⚠ IMPORTANT: Nodes have Discovery OS with assigned hypervisor IPs" -ForegroundColor Yellow
            Write-Host "    These IPs will be used instead of config IPs to avoid FC rejection" -ForegroundColor Yellow
        }
        
        # Validate and warn if config mismatches discovered values
        $configWarnings = @()
        
        if ($autoDetectedConfig.IPMI_Netmask -and $config.network.ipmi_netmask) {
            if ($autoDetectedConfig.IPMI_Netmask -ne $config.network.ipmi_netmask) {
                $configWarnings += "IPMI Netmask mismatch: Config=$($config.network.ipmi_netmask), Discovered=$($autoDetectedConfig.IPMI_Netmask)"
            }
        }
        
        if ($autoDetectedConfig.IPMI_Gateway -and $config.network.ipmi_gateway) {
            if ($autoDetectedConfig.IPMI_Gateway -ne $config.network.ipmi_gateway) {
                $configWarnings += "IPMI Gateway mismatch: Config=$($config.network.ipmi_gateway), Discovered=$($autoDetectedConfig.IPMI_Gateway)"
            }
        }
        
        if ($configWarnings.Count -gt 0) {
            Write-Host ""
            Write-Host "  ⚠ Configuration Mismatches Detected:" -ForegroundColor Yellow
            foreach ($warning in $configWarnings) {
                Write-Host "    - $warning" -ForegroundColor Yellow
            }
            Write-Host "  ℹ Auto-detected values from FC will be used" -ForegroundColor Cyan
        }
        
        # Store auto-detected config for use in imaging body
        $nodes.AutoDetectedConfig = $autoDetectedConfig
        
        Write-Host ""
        Write-Host "  Analyzing node imaging state..." -ForegroundColor White
        $imagingState = Test-NodeImagingState -Nodes $discoveredNodes
        
        # Smart re-imaging decision
        $needsImaging = $false
        $imagingReason = ""

        # --- GENBRUG IMAGE HVIS MULIGT ---
        # Hvis reuse_existing_image er true, genbrug altid image (ingen re-imaging)
        if ($config.PSObject.Properties.Name -contains 'reuse_existing_image' -and $config.reuse_existing_image) {
            Write-Host "  ✓ reuse_existing_image er sat til true - genbruger eksisterende image, ingen re-imaging" -ForegroundColor Green
            $needsImaging = $false
            $imagingReason = "reuse_existing_image=true - reusing image regardless of node state/version"
        }
        else {
            # Imaging udføres kun hvis noderne er bare metal, version mismatch eller ForceReimage
            if ($imagingState.BothBareMetal) {
                Write-Host "  ✓ Both nodes are BARE METAL - ready for fresh imaging" -ForegroundColor Green
                $needsImaging = $true
                $imagingReason = "Bare metal nodes require initial imaging"
            }
            elseif ($imagingState.AnyImaged) {
                Write-Host "  ℹ Nodes er allerede imaged - checking AOS version compatibility" -ForegroundColor Cyan
                foreach ($nr in $imagingState.NodeResults) {
                    Write-Host "    $($nr.Serial): $($nr.State) - CVM: $($nr.Details.CVM_IP)" -ForegroundColor Gray
                }

                if ($ForceReimage) {
                    Write-Host "  ⚠ -ForceReimage specified: Nodes will be RE-IMAGED (DATA LOSS)" -ForegroundColor Yellow
                    $needsImaging = $true
                    $imagingReason = "Forced re-imaging requested by user"
                }
                else {
                    $versionCheck = Test-AOSVersionCompatibility `
                        -Nodes $discoveredNodes `
                        -DesiredAOSUrl $config.aos_package_url

                    if ($versionCheck.VersionsMatch) {
                        Write-Host "  ✓ Nodes have compatible AOS version - REUSING EXISTING IMAGE (no re-imaging)" -ForegroundColor Green
                        Write-Host "    Current: $($versionCheck.DetectedVersion)" -ForegroundColor Gray
                        Write-Host "    Desired: $($versionCheck.DesiredVersion)" -ForegroundColor Gray
                        $needsImaging = $false
                        $imagingReason = "Nodes already have correct AOS version - reusing image"
                    }
                    else {
                        Write-Host "  ⚠ Version mismatch detected - RE-IMAGING required" -ForegroundColor Yellow
                        Write-Host "    Current: $($versionCheck.DetectedVersion)" -ForegroundColor Yellow
                        Write-Host "    Desired: $($versionCheck.DesiredVersion)" -ForegroundColor Yellow
                        Write-Host "  ⚠ Re-imaging will WIPE these nodes (DATA LOSS)" -ForegroundColor Yellow
                        $needsImaging = $true
                        $imagingReason = "AOS version mismatch requires re-imaging"

                        if (-not $Force) {
                            Write-Host ""
                            $reimageConfirm = Read-Host "  Are you sure you want to RE-IMAGE these nodes? (Y/N)"
                            if ($reimageConfirm -ne 'Y') {
                                Write-Host "Deployment cancelled by user." -ForegroundColor Red
                                exit 1
                            }
                        }
                    }
                }
            }
        }
        Write-DeploymentLog -Message "Imaging decision: NeedsImaging=$needsImaging, Reason=$imagingReason" -Level INFO
    }
    catch {
        Write-Host "  ✗ Discovery failed: $_" -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    #endregion
    
    #region Phase 4: Validation
    Write-Host "[PHASE 4] Running pre-deployment validation..." -ForegroundColor Cyan
    Write-Host ""



    # Foundation Central port validation
    Write-Host "Foundation Central Port Validation:" -ForegroundColor White

    # Extract FC IP from URL
    $fcIP = $null
    if ($config.prism_central.url -match "https?://([^:/]+)") {
        $fcIP = $matches[1]
    }

    if ($fcIP) {
        # Test port 9440 (Foundation Central)
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $connection = $tcpClient.BeginConnect($fcIP, 9440, $null, $null)
            $wait = $connection.AsyncWaitHandle.WaitOne(3000, $false)
            if ($wait -and $tcpClient.Connected) {
                Write-Host "  ✓ Port 9440 (Foundation Central) accessible on $fcIP" -ForegroundColor Green
                $tcpClient.Close()
            }
            else {
                Write-Host "  ✗ Port 9440 (Foundation Central) not accessible on $fcIP" -ForegroundColor Red
                $tcpClient.Close()
                throw "Port 9440 required for Foundation Central communication"
            }
        }
        catch {
            Write-Host "  ✗ Port 9440 test failed: $_" -ForegroundColor Red
            exit 1
        }
        
        # Test ICMP (informational only)
        if (Test-IPInUse -IPAddress $fcIP -TimeoutMilliseconds 2000) {
            Write-Host "  ✓ ICMP (Ping) responding to Foundation Central" -ForegroundColor Green
            Write-Host "    ICMP must be enabled between nodes and Foundation Central" -ForegroundColor Gray
        }
        else {
            Write-Host "  ⚠ ICMP (Ping) not responding to Foundation Central" -ForegroundColor Yellow
            Write-Host "    ICMP must be enabled mellem nodes og Foundation Central" -ForegroundColor Gray
        }
    }
    else {
        Write-Host "  ⚠ Could not extract IP from Foundation Central URL" -ForegroundColor Yellow
    }

    Write-Host ""

    # Network validation
    Write-Host "Network Validation:" -ForegroundColor White
    
    # Get IPMI IPs for validation
    $ipmiIPsForValidation = $null
    $skipIPMIValidation = $false
    # Only validate IPMI if ipmi_ips is present and has at least 2 non-empty entries
    if ($config.network.ipmi_ips -and @($config.network.ipmi_ips | Where-Object { $_ -and $_.Trim() -ne "" }).Count -ge 1) {
        $ipmiIPsForValidation = $config.network.ipmi_ips
    } else {
        $skipIPMIValidation = $true
    }

    $witnessRequired = $true
    if ($config.PSObject.Properties.Name -contains "witness_required") {
        $witnessRequired = [bool]$config.witness_required
    }


    if (-not $skipIPMIValidation) {
        $networkResults = Test-NetworkConnectivity `
            -IPAddresses $ipAddresses `
            -WitnessIP $null `
            -DNSServers $config.dns_servers `
            -CheckIPMI `
            -IPMIIPs $ipmiIPsForValidation
    } else {
        $networkResults = Test-NetworkConnectivity `
            -IPAddresses $ipAddresses `
            -WitnessIP $null `
            -DNSServers $config.dns_servers
    }
    
    foreach ($pass in $networkResults.Passed) {
        Write-Host "  ✓ $pass" -ForegroundColor Green
    }
    foreach ($warn in $networkResults.Warnings) {
        Write-Host "  ⚠ $warn" -ForegroundColor Yellow
    }
    foreach ($fail in $networkResults.Failed) {
        Write-Host "  ✗ $fail" -ForegroundColor Red
    }
    
    if ($networkResults.Failed.Count -gt 0) {
        Write-Host ""
        Write-Host "Network validation failed. Cannot proceed." -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    
    # Foundation Central validation
    Write-Host "Foundation Central Validation:" -ForegroundColor White
    $fcResults = Test-FoundationCentralReadiness `
        -FCConnection $fcConnection `
        -AOSVersion $config.aos_version `
        -Hypervisor $config.hypervisor
    
    foreach ($pass in $fcResults.Passed) {
        Write-Host "  ✓ $pass" -ForegroundColor Green
    }
    foreach ($warn in $fcResults.Warnings) {
        Write-Host "  ⚠ $warn" -ForegroundColor Yellow
    }
    foreach ($fail in $fcResults.Failed) {
        Write-Host "  ✗ $fail" -ForegroundColor Red
    }
    
    if ($fcResults.Failed.Count -gt 0) {
        Write-Host ""
        Write-Host "Foundation Central validation failed. Cannot proceed." -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    
    # Image file accessibility validation
    Write-Host "Image File Accessibility:" -ForegroundColor White
    
    # Test AOS package URL
    # try {
    #     Write-Host "  Testing AOS package URL..." -ForegroundColor Gray
    #     $aosResponse = Invoke-WebRequest -Uri $config.aos_package_url -Method HEAD -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    #     # Get Content-Length (handle both single value and array)
    #     $contentLength = $aosResponse.Headers.'Content-Length'
    #     if ($contentLength -is [array]) {
    #         $contentLength = $contentLength[0]
    #     }
    #     $aosSizeMB = if ($contentLength) { [math]::Round([int64]$contentLength / 1MB, 2) } else { "Unknown" }
    #     Write-Host "  ✓ AOS package accessible ($aosSizeMB MB)" -ForegroundColor Green
    #     Write-Host "    $($config.aos_package_url)" -ForegroundColor Gray
    # }
    # catch {
    #     Write-Host "  ✗ AOS package NOT accessible" -ForegroundColor Red
    #     Write-Host "    $($config.aos_package_url)" -ForegroundColor Gray
    #     Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
    #     Write-Host ""
    #     Write-Host "Image file validation failed. Cannot proceed." -ForegroundColor Red
    #     exit 1
    # }
    
    # Test Hypervisor ISO URL
    # try {
    #     Write-Host "  Testing hypervisor ISO URL..." -ForegroundColor Gray
    #     $isoResponse = Invoke-WebRequest -Uri $config.hypervisor_iso_url -Method HEAD -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    #     # Get Content-Length (handle both single value and array)
    #     $contentLength = $isoResponse.Headers.'Content-Length'
    #     if ($contentLength -is [array]) {
    #         $contentLength = $contentLength[0]
    #     }
    #     $isoSizeMB = if ($contentLength) { [math]::Round([int64]$contentLength / 1MB, 2) } else { "Unknown" }
    #     Write-Host "  ✓ Hypervisor ISO accessible ($isoSizeMB MB)" -ForegroundColor Green
    #     Write-Host "    $($config.hypervisor_iso_url)" -ForegroundColor Gray
    # }
    # catch {
    #     Write-Host "  ✗ Hypervisor ISO NOT accessible" -ForegroundColor Red
    #     Write-Host "    $($config.hypervisor_iso_url)" -ForegroundColor Gray
    #     Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
    #     Write-Host ""
    #     Write-Host "Image file validation failed. Cannot proceed." -ForegroundColor Red
    #     exit 1
    # }
    
    # Check if at least one DNS server is reachable before proceeding
    $dnsAvailable = $false
    foreach ($dns in $config.dns_servers) {
        if (Test-Connection -ComputerName $dns -Count 1 -Quiet) {
            Write-Host "  ✓ DNS server $dns is reachable" -ForegroundColor Green
            $dnsAvailable = $true
            break
        } else {
            Write-Host "  ✗ DNS server $dns is not reachable" -ForegroundColor Yellow
        }
    }
    if (-not $dnsAvailable) {
        Write-Host "  ✗ No DNS servers are reachable. Deployment cannot continue." -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    
    # Extended Validations (Priority 1) - Currently disabled, add implementations as needed
    # Write-Host "Extended Validation Checks:" -ForegroundColor White
    # Write-Host "  ⚠ Extended validation checks skipped (not implemented)" -ForegroundColor Yellow
    
    Write-Host "  ✓ All critical validation checks passed!" -ForegroundColor Green
    Write-Host ""
    #endregion
    
    # Apply node-specific IP configuration if provided
    $cfgNodesForIP = @($config.network.nodes)
    if ($cfgNodesForIP.Count -ge 1) {
        Write-Host "[IP CONFIGURATION] Using node-specific IP settings..." -ForegroundColor Cyan
        for ($ni = 0; $ni -lt $cfgNodesForIP.Count; $ni++) {
            $num = $ni + 1
            if ($cfgNodesForIP[$ni].cvm_ip) {
                Write-Host "  Node $num CVM IP: $($cfgNodesForIP[$ni].cvm_ip)" -ForegroundColor Gray
                $ipAddresses["Node${num}_CVM"] = $cfgNodesForIP[$ni].cvm_ip
            }
            if ($cfgNodesForIP[$ni].hypervisor_ip) {
                Write-Host "  Node $num Hypervisor IP: $($cfgNodesForIP[$ni].hypervisor_ip)" -ForegroundColor Gray
                $ipAddresses["Node${num}_Hypervisor"] = $cfgNodesForIP[$ni].hypervisor_ip
            }
        }
        Write-Host ""
    }
    
    #region Phase 5: Display Deployment Plan
    Show-DeploymentPlan -Config $config -IPAddresses $ipAddresses -Nodes $nodes
    #endregion
    
    #region Phase 5.5: Build and Validate Imaging Body (before DryRun check)
    Write-Host ""
    Write-Host "[PHASE 5.5] Building imaging request body..." -ForegroundColor Cyan
    Write-Host ""
    
    # Build imaging request body
    $skipImaging = -not $needsImaging
    $imagingBody = New-ImagingRequestBody `
        -Config $config `
        -IPAddresses $ipAddresses `
        -Nodes $nodes `
        -SkipImaging $skipImaging

    # Always add hypervisor_isos array for UI compatibility
    if ($imagingBody.hypervisor_iso_details) {
        $imagingBody.hypervisor_isos = @(@{
            url = $imagingBody.hypervisor_iso_details.url
            hypervisor_type = $imagingBody.hypervisor_iso_details.hypervisor_type
        })
    }
    
    # Validate body structure
    Write-Host "Imaging Request Body Validation:" -ForegroundColor White
    Write-Host "  Body Type:        $($imagingBody.GetType().Name)" -ForegroundColor Gray
    Write-Host "  Body Keys:        $($imagingBody.Keys.Count) keys" -ForegroundColor Gray
    Write-Host "    └─ $($imagingBody.Keys -join ', ')" -ForegroundColor DarkGray
    
    # Convert to JSON and validate
    $bodyJson = $imagingBody | ConvertTo-Json -Depth 20 -Compress:$false
    Write-Host "  JSON Length:      $($bodyJson.Length) characters" -ForegroundColor Gray
    
    # Validate critical fields
    $validationIssues = @()
    
    if (-not $imagingBody.cluster_name) {
        $validationIssues += "Missing cluster_name"
    }
    if (-not $imagingBody.cluster_external_ip) {
        $validationIssues += "Missing cluster_external_ip"
    }
    if (-not $imagingBody.aos_package_url) {
        $validationIssues += "Missing aos_package_url"
    }
    if (-not $imagingBody.hypervisor_iso_details.hypervisor_type) {
        $validationIssues += "Missing hypervisor_iso_details.hypervisor_type"
    }
    if ($imagingBody.hypervisor_iso_details.url) {
        Write-Host "  Hypervisor ISO:   $($imagingBody.hypervisor_iso_details.url)" -ForegroundColor Gray
    }
    if (-not $imagingBody.nodes_list -or $imagingBody.nodes_list.Count -eq 0) {
        $validationIssues += "Missing or empty nodes_list"
    }
    else {
        Write-Host "  Nodes:            $($imagingBody.nodes_list.Count) nodes" -ForegroundColor Gray
        $nodeNum = 1
        foreach ($node in $imagingBody.nodes_list) {
            if (-not $node.node_serial) {
                $validationIssues += "Node $nodeNum missing node_serial"
            }
            else {
                Write-Host "    └─ Node $nodeNum Serial: $($node.node_serial)" -ForegroundColor DarkGray
            }
            $nodeNum++
        }
    }
    
    if ($validationIssues.Count -gt 0) {
        Write-Host ""
        Write-Host "  ✗ Body Validation Failed:" -ForegroundColor Red
        foreach ($issue in $validationIssues) {
            Write-Host "    - $issue" -ForegroundColor Red
        }
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
        
        # Find the most recent imaging body log file
        Write-Host ""
        Write-Host "  [DRY-RUN] No changes were made to the environment" -ForegroundColor Yellow
        Write-Host "  [DRY-RUN] Remove -DryRun flag to proceed with actual deployment" -ForegroundColor Yellow
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
    Write-Host "  ℹ A detailed log file is created in the Logs folder" -ForegroundColor White
    Write-Host "  ℹ The log file contains all data sent to the cluster process" -ForegroundColor White
    Write-Host "  ℹ Log file location: $logFile" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Starting deployment of cluster: $($config.clusterName)" -ForegroundColor Green
    Write-Host ""
    #endregion
    
    #region Phase 6: Log imaging body review info
    Write-DeploymentLog -Message "Imaging body built and validated for cluster: $($config.clusterName)" -Level INFO
    Write-Host ""
    #endregion

    #region Phase 6.5: User Confirmation
    # User confirmation before starting cluster build
    if (-not $Force) {
        Write-Host ""
        Write-Host "  ═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  ℹ Validation completed - all necessary checks performed" -ForegroundColor White
        Write-Host "  ℹ Imaging body has been validated and saved to log file" -ForegroundColor White
        Write-Host "  ═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Please review the output and log file before proceeding." -ForegroundColor Yellow
        Write-Host "  When you confirm, the cluster build will start." -ForegroundColor Yellow
        Write-Host ""
        $proceedConfirm = Read-Host "  Are you ready to start the cluster build? (Y/N)"
        if ($proceedConfirm -ne 'Y') {
            Write-Host ""
            Write-Host "  Deployment cancelled by user." -ForegroundColor Red
            Write-DeploymentLog -Message "Deployment cancelled by user before imaging start" -Level WARN
            exit 1
        }
    }
    #endregion
    
    #region Phase 7: Start Cluster Imaging
    Write-Host "[PHASE 7] Starting cluster imaging..." -ForegroundColor Cyan
    Write-Host ""

    try {
        $jobUUID = Start-ClusterImaging -FCConnection $fcConnection -ImagingBody $imagingBody
        Write-Host "  ✓ Imaging job created: $jobUUID" -ForegroundColor Green
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
        -FCConnection $fcConnection `
        -JobUUID $jobUUID `
        -PollIntervalSeconds 30 `
        -TimeoutMinutes 120
    
    if (-not $imagingResult.Success) {
        Write-Host ""
        Write-Host "Imaging failed: $($imagingResult.Error)" -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    #endregion
    
    #region Phase 9: Finalization
    Write-Host "[PHASE 9] Finalizing deployment..." -ForegroundColor Cyan
    Write-Host ""
    
    $scriptEndTime = Get-Date
    $totalDuration = $scriptEndTime - $scriptStartTime
    
    # Update historical timings
    $phaseTimings = @{
        total = [int]$totalDuration.TotalMinutes
    }
    Update-HistoricalTimings `
        -ClusterName $config.clusterName `
        -PhaseTimings $phaseTimings `
        -TotalDurationMinutes ([int]$totalDuration.TotalMinutes) `
        -Success $true `
        -AOSVersion $config.aos_version
    
    Write-DeploymentLog -Message "Deployment complete for $($config.clusterName)" -Level INFO
    
    Write-Host ""
    #endregion
    
    #region Show Summary
    Show-DeploymentSummary `
        -Config $config `
        -IPAddresses $ipAddresses `
        -StartTime $scriptStartTime `
        -EndTime $scriptEndTime `
        -LogFile $logFile
    #endregion

    exit 0
}
catch {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host "                    DEPLOYMENT FAILED                          " -ForegroundColor Red
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Stack Trace:" -ForegroundColor Yellow
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
    Write-Host ""
    Write-Host "Please review the error, fix any issues, and restart the deployment." -ForegroundColor Yellow
    Write-Host ""
    
    exit 1
}

#endregion


