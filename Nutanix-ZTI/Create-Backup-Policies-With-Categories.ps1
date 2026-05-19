<#
.SYNOPSIS
    Manage Prism Central Backup Policies for Nutanix Clusters (with Category support)
    
.DESCRIPTION
    This script connects to Prism Central, identifies the PC hosting cluster,
    creates or updates backup policies (Daily, Weekly, Monthly), and adds
    newly deployed clusters to these policies.

    Before creating policies, the script checks for a "Backup" category with values:
    Daily-Backup, Weekly-Backup, Monthly-Backup. If found, each policy is created
    with its matching category filter. If not found, policies are created without
    category filtering (applies to all VMs).
    
.PARAMETER ConfigFile
    Path to the cluster JSON config file.
    
.EXAMPLE
    .\Manage-PC-Backup-Policies-WithCategories.ps1 -ConfigFile ".\Configs\DKLAB-1-Create.json"
    
.NOTES
    Author: DCES Core Service Team
    Date: March 24, 2026
    Version: 2.0 - Added Backup category support

    Developed and maintained by DCES core service
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile
)

# Load config
$config         = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
$PrismCentralIP = $config.prism_central.ip
$Username       = $config.prism_central.username
$Password       = $config.prism_central.password
$NewClusterName = $config.clusterName

if (-not $PrismCentralIP) {
    Write-Host "ERROR: 'prism_central.ip' not found in config file: $ConfigFile" -ForegroundColor Red
    exit 1
}
if (-not $NewClusterName) {
    Write-Host "ERROR: 'clusterName' not found in config file: $ConfigFile" -ForegroundColor Red
    exit 1
}

# Disable certificate validation for self-signed certs
if ($PSVersionTable.PSVersion.Major -ge 6) {
    # PowerShell 6+ (Core)
    # Certificate validation is handled per request using -SkipCertificateCheck
} else {
    # Windows PowerShell 5.1 and earlier
    Add-Type @"
    using System.Net;
    using System.Net.Security;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# Script-level variables (will be initialized in Main)
$script:PrismCentralBaseURL = ""
$script:Headers = @{}

#region Helper Functions

function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch($Level) {
        'Info'    { 'Cyan' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Invoke-PrismAPI {
    param(
        [string]$Method = "GET",
        [string]$Endpoint,
        [object]$Body = $null
    )
    
    $uri = "$script:PrismCentralBaseURL/$Endpoint"
    
    try {
        $params = @{
            Uri = $uri
            Method = $Method
            Headers = $script:Headers
            ContentType = "application/json"
        }
        
        if ($Body) {
            $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
        }
        
        # Add SkipCertificateCheck for PowerShell 6+
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $params.SkipCertificateCheck = $true
        }
        
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        Write-LogMessage "API Error: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Get-AllClusters {
    Write-LogMessage "Retrieving all clusters from Prism Central..."
    
    $body = @{
        kind = "cluster"
        length = 500
    }
    
    $response = Invoke-PrismAPI -Method POST -Endpoint "clusters/list" -Body $body
    
    # Filter out PC itself if it appears as a cluster
    $realClusters = $response.entities | Where-Object { 
        $_.spec.name -notmatch "^Unnamed$" -and 
        $_.status.resources.config.service_list -notcontains "PRISM_CENTRAL" 
    }
    
    $pcEntry = $response.entities | Where-Object {
        $_.status.resources.config.service_list -contains "PRISM_CENTRAL"
    }
    
    Write-LogMessage "Found $($realClusters.Count) Nutanix clusters" -Level Success
    if ($pcEntry) {
        Write-LogMessage "Note: Also found PC entry '$($pcEntry.spec.name)' (not a real cluster)" -Level Info
    }
    
    # Log all cluster names for debugging
    Write-LogMessage "Nutanix Clusters:" -Level Info
    foreach ($cluster in $realClusters) {
        $services = $cluster.status.resources.config.service_list -join ", "
        Write-LogMessage "  - $($cluster.spec.name) (Services: $services)" -Level Info
    }
    
    return $response.entities
}

function Get-PrismCentralCluster {
    param([array]$Clusters)
    
    Write-LogMessage "Identifying cluster hosting Prism Central..." -Level Info
    
    # First, find the "cluster" entry that has PRISM_CENTRAL service
    # This is NOT a real cluster - it's PC registering itself, but we can use the name
    $pcEntry = $Clusters | Where-Object { $_.status.resources.config.service_list -contains "PRISM_CENTRAL" }
    
    if ($pcEntry) {
        $pcVMName = $pcEntry.spec.name
        Write-LogMessage "Found PC entry: $pcVMName (this is PC VM name, not a cluster)" -Level Info
        
        # Search for the actual VM by name to get the real VM UUID
        $body = @{
            kind = "vm"
            filter = "vm_name==$pcVMName"
            length = 10
        }
        
        try {
            Write-LogMessage "Searching for VM named '$pcVMName'..." -Level Info
            $vmSearchResponse = Invoke-PrismAPI -Method POST -Endpoint "vms/list" -Body $body
            
            if ($vmSearchResponse.entities.Count -gt 0) {
                $pcVM = $vmSearchResponse.entities[0]
                $pcVMUUID = $pcVM.metadata.uuid
                Write-LogMessage "Found PC VM: $($pcVM.spec.name) (VM UUID: $pcVMUUID)" -Level Info
                
                # Now get the full VM details using the correct VM UUID
                Write-LogMessage "Fetching PC VM details..." -Level Info
                $pcVMDetail = Invoke-PrismAPI -Method GET -Endpoint "vms/$pcVMUUID"
                
                # Get cluster reference from spec (primary source)
                $hostClusterUUID = $null
                $hostClusterName = $null
                
                if ($pcVMDetail.spec.cluster_reference) {
                    $hostClusterUUID = $pcVMDetail.spec.cluster_reference.uuid
                    $hostClusterName = $pcVMDetail.spec.cluster_reference.name
                    Write-LogMessage "PC VM cluster reference: $hostClusterName (UUID: $hostClusterUUID)" -Level Info
                }
                elseif ($pcVMDetail.status.cluster_reference) {
                    $hostClusterUUID = $pcVMDetail.status.cluster_reference.uuid
                    $hostClusterName = $pcVMDetail.status.cluster_reference.name
                    Write-LogMessage "PC VM cluster reference: $hostClusterName (UUID: $hostClusterUUID)" -Level Info
                }
                
                if ($hostClusterUUID) {
                    # Find the actual cluster from the list (exclude PC entry itself)
                    $hostCluster = $Clusters | Where-Object { 
                        $_.metadata.uuid -eq $hostClusterUUID -and 
                        $_.status.resources.config.service_list -notcontains "PRISM_CENTRAL"
                    }
                    
                    if ($hostCluster) {
                        Write-LogMessage "Prism Central is running on cluster: $($hostCluster.spec.name)" -Level Success
                        return $hostCluster
                    } else {
                        Write-LogMessage "Could not find cluster with UUID $hostClusterUUID in cluster list" -Level Error
                        Write-LogMessage "Available clusters: $(($Clusters | Where-Object { $_.status.resources.config.service_list -notcontains 'PRISM_CENTRAL' }).spec.name -join ', ')" -Level Info
                    }
                } else {
                    Write-LogMessage "Could not extract cluster reference from PC VM details" -Level Error
                }
            } else {
                Write-LogMessage "VM search for '$pcVMName' returned no results" -Level Error
            }
        }
        catch {
            Write-LogMessage "Error: $($_.Exception.Message)" -Level Error
        }
    } else {
        Write-LogMessage "Could not find PC entry in clusters list" -Level Error
    }
    
    Write-LogMessage "Could not determine which cluster hosts Prism Central" -Level Error
    return $null
}

function Get-ProtectionPolicies {
    Write-LogMessage "Retrieving existing protection policies..."
    
    $body = @{
        kind = "protection_rule"
        length = 500
    }
    
    $response = Invoke-PrismAPI -Method POST -Endpoint "protection_rules/list" -Body $body
    Write-LogMessage "Found $($response.entities.Count) protection policies" -Level Info
    return $response.entities
}

function Get-AvailabilityZones {
    Write-LogMessage "Retrieving Availability Zones from Prism Central..." -Level Info
    
    $body = @{
        kind = "availability_zone"
        length = 500
    }
    
    try {
        $response = Invoke-PrismAPI -Method POST -Endpoint "availability_zones/list" -Body $body
        Write-LogMessage "Found $($response.entities.Count) Availability Zones" -Level Success
        
        # Log AZ details
        foreach ($az in $response.entities) {
            $azName = $az.spec.resources.name
            $azUrl = $az.spec.resources.management_url
            Write-LogMessage "  - AZ: $azName (URL: $azUrl)" -Level Info
        }
        
        return $response.entities
    }
    catch {
        Write-LogMessage "Error retrieving Availability Zones: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Get-AvailabilityZoneForCluster {
    param(
        [array]$AvailabilityZones,
        [object]$Cluster
    )
    
    # Try to match AZ by cluster UUID
    $clusterUUID = $Cluster.metadata.uuid
    $clusterName = $Cluster.spec.name
    
    Write-LogMessage "  Looking for AZ for cluster: $clusterName (UUID: $clusterUUID)" -Level Info
    
    # Try exact UUID match first
    $matchingAZ = $AvailabilityZones | Where-Object {
        $azUrl = $_.spec.resources.management_url
        $azUUID = $_.metadata.uuid
        
        # Check if AZ UUID matches cluster UUID, or if management URL contains cluster UUID
        return ($azUUID -eq $clusterUUID) -or ($azUrl -eq $clusterUUID) -or ($azUrl -match $clusterUUID)
    }
    
    if ($matchingAZ) {
        Write-LogMessage "  Found matching AZ: $($matchingAZ.metadata.uuid)" -Level Info
        return $matchingAZ
    }
    
    # If no match, try by name
    $matchingAZ = $AvailabilityZones | Where-Object {
        $azName = $_.spec.resources.name
        return ($azName -eq $clusterName)
    }
    
    if ($matchingAZ) {
        Write-LogMessage "  Found matching AZ by name: $azName" -Level Info
        return $matchingAZ
    }
    
    Write-LogMessage "  No AZ match found for cluster $clusterName" -Level Warning
    return $null
}

#region NEW: Category Functions

function Get-BackupCategoryValues {
    <#
    .SYNOPSIS
        Checks if the "Backup" category exists in Prism Central and retrieves its values.
    .OUTPUTS
        Hashtable with:
          - Found      : $true/$false - whether Backup category exists
          - Values     : array of value strings found under the Backup key
          - HasDaily   : $true/$false
          - HasWeekly  : $true/$false
          - HasMonthly : $true/$false
    #>
    
    Write-LogMessage "Checking for 'Backup' category in Prism Central..." -Level Info
    
    $result = @{
        Found      = $false
        Values     = @()
        HasDaily   = $false
        HasWeekly  = $false
        HasMonthly = $false
    }
    
    # Step 1: List all category keys to confirm "Backup" exists
    try {
        $keysBody = @{
            kind   = "category"
            length = 500
        }
        $keysResponse = Invoke-PrismAPI -Method POST -Endpoint "categories/list" -Body $keysBody
        
        Write-LogMessage "Found $($keysResponse.entities.Count) category key(s) in Prism Central" -Level Info
        
        $backupKey = $keysResponse.entities | Where-Object { $_.name -eq "Backup" }
        
        if (-not $backupKey) {
            Write-LogMessage "  'Backup' category key NOT found in Prism Central" -Level Warning
            Write-LogMessage "  Available category keys:" -Level Info
            foreach ($key in $keysResponse.entities) {
                Write-LogMessage "    - $($key.name)" -Level Info
            }
            return $result
        }
        
        Write-LogMessage "  'Backup' category key found" -Level Success
        $result.Found = $true
    }
    catch {
        Write-LogMessage "Error listing category keys: $($_.Exception.Message)" -Level Error
        return $result
    }
    
    # Step 2: List all values under the "Backup" category key
    try {
        $valuesBody = @{
            kind   = "category"
            length = 500
        }
        $valuesResponse = Invoke-PrismAPI -Method POST -Endpoint "categories/Backup/list" -Body $valuesBody
        
        $foundValues = @()
        foreach ($val in $valuesResponse.entities) {
            $foundValues += $val.value
        }
        
        $result.Values = $foundValues
        
        Write-LogMessage "  'Backup' category values found: $($foundValues -join ', ')" -Level Info
        
        # Check for required values
        $result.HasDaily   = $foundValues -contains "Daily-Backup"
        $result.HasWeekly  = $foundValues -contains "Weekly-Backup"
        $result.HasMonthly = $foundValues -contains "Monthly-Backup"
        
        if ($result.HasDaily)   { Write-LogMessage "  ✓ Found value: Daily-Backup"   -Level Success }
        else                    { Write-LogMessage "  ✗ Missing value: Daily-Backup"   -Level Warning }
        
        if ($result.HasWeekly)  { Write-LogMessage "  ✓ Found value: Weekly-Backup"  -Level Success }
        else                    { Write-LogMessage "  ✗ Missing value: Weekly-Backup"  -Level Warning }
        
        if ($result.HasMonthly) { Write-LogMessage "  ✓ Found value: Monthly-Backup" -Level Success }
        else                    { Write-LogMessage "  ✗ Missing value: Monthly-Backup" -Level Warning }
    }
    catch {
        Write-LogMessage "Error listing values for 'Backup' category: $($_.Exception.Message)" -Level Error
        # Category key exists but values could not be retrieved - still mark as found
    }
    
    return $result
}

function New-BackupCategoryIfMissing {
    <#
    .SYNOPSIS
        Creates the "Backup" category key and/or any missing required values
        (Daily-Backup, Weekly-Backup, Monthly-Backup) if they do not already exist.
    .PARAMETER CategoryStatus
        The hashtable returned by Get-BackupCategoryValues.
    #>
    param(
        [hashtable]$CategoryStatus
    )

    $requiredValues = @(
        @{ Value = "Daily-Backup";   Has = $CategoryStatus.HasDaily   },
        @{ Value = "Weekly-Backup";  Has = $CategoryStatus.HasWeekly  },
        @{ Value = "Monthly-Backup"; Has = $CategoryStatus.HasMonthly }
    )

    # --- Create the Backup key if it does not exist ---
    if (-not $CategoryStatus.Found) {
        Write-LogMessage "  Creating 'Backup' category key..." -Level Warning
        try {
            $createKeyBody = @{
                name        = "Backup"
                description = "Backup schedule category - Created by DCES Core Service"
            }
            # Nutanix v3: PUT /categories/{name} creates or updates a category key
            Invoke-PrismAPI -Method PUT -Endpoint "categories/Backup" -Body $createKeyBody | Out-Null
            Write-LogMessage "  ✓ 'Backup' category key created successfully" -Level Success
        }
        catch {
            Write-LogMessage "  Failed to create 'Backup' category key: $($_.Exception.Message)" -Level Error
            throw
        }
    }

    # --- Create each missing value ---
    foreach ($entry in $requiredValues) {
        if (-not $entry.Has) {
            Write-LogMessage "  Creating missing value '$($entry.Value)'..." -Level Warning
            try {
                # Nutanix v3: PUT /categories/{name}/{value} creates a category value
                $createValueBody = @{
                    value       = $entry.Value
                    description = "$($entry.Value) backup schedule - Created by DCES Core Service"
                }
                Invoke-PrismAPI -Method PUT -Endpoint "categories/Backup/$($entry.Value)" -Body $createValueBody | Out-Null
                Write-LogMessage "  ✓ Value '$($entry.Value)' created successfully" -Level Success
            }
            catch {
                Write-LogMessage "  Failed to create value '$($entry.Value)': $($_.Exception.Message)" -Level Error
                throw
            }
        }
    }
}

#endregion

function New-ProtectionPolicy {
    param(
        [string]$PolicyName,
        [string]$ScheduleType,
        [hashtable]$ScheduleConfig,
        [object]$RemoteCluster,
        [array]$PrimaryClusters,
        [array]$AvailabilityZones,
        [string]$CategoryValue = ""   # e.g. "Daily-Backup" - empty means no category filter
    )
    
    Write-LogMessage "Creating protection policy: $PolicyName..." -Level Info
    
    # Build category filter
    # If a CategoryValue is supplied (and the Backup key was confirmed to exist),
    # scope the policy to only VMs tagged with Backup=<CategoryValue>.
    # Otherwise fall back to matching all VMs (empty params).
    if ($CategoryValue -ne "") {
        Write-LogMessage "  Applying category filter: Backup = $CategoryValue" -Level Info
        $categoryFilter = @{
            type   = "CATEGORIES_MATCH_ANY"
            params = @{
                "Backup" = @($CategoryValue)
            }
        }
    } else {
        Write-LogMessage "  No category filter applied (policy covers all VMs)" -Level Warning
        $categoryFilter = @{
            type   = "CATEGORIES_MATCH_ANY"
            params = @{}
        }
    }
    
    # Build availability zone list - CRITICAL: Only 2 entries total
    # Entry 0: Primary location with cluster_uuid_list (array of all primary clusters)
    # Entry 1: Remote location with cluster_uuid (single PC cluster)
    $orderedAZList = @()
    
    # Get the Local AZ UUID (should be the same for all local clusters)
    $localAZ = $AvailabilityZones | Select-Object -First 1
    $localAZUrl = ""
    
    if ($localAZ) {
        # Use the AZ's management_url (which is actually the AZ UUID)
        $localAZUrl = $localAZ.spec.resources.management_url
        Write-LogMessage "Using Local AZ: $localAZUrl" -Level Info
    } else {
        Write-LogMessage "WARNING: No Availability Zone found, using empty AZ URL" -Level Warning
    }
    
    # Build array of primary cluster UUIDs
    $primaryClusterUUIDs = @()
    foreach ($cluster in $PrimaryClusters) {
        Write-LogMessage "  Adding primary cluster: $($cluster.spec.name)" -Level Info
        $primaryClusterUUIDs += $cluster.metadata.uuid
    }
    
    # Entry 0: Primary location (all source clusters as array)
    $orderedAZList += @{
        availability_zone_url   = $localAZUrl
        availability_zone_label = "0"
        cluster_uuid_list       = @($primaryClusterUUIDs)
        target_type             = "AOS_CLUSTER"
    }
    
    # Entry 1: Remote cluster (PC cluster - single target)
    Write-LogMessage "  Adding remote cluster: $($RemoteCluster.spec.name)" -Level Info
    $orderedAZList += @{
        availability_zone_url   = $localAZUrl
        availability_zone_label = "1"
        cluster_uuid            = $RemoteCluster.metadata.uuid
        target_type             = "AOS_CLUSTER"
    }
    
    # Build snapshot schedule
    $snapshotSchedule = @{
        recovery_point_objective_secs = $ScheduleConfig.RPO
        local_snapshot_retention_policy = @{
            num_snapshots = $ScheduleConfig.LocalRetention
        }
        remote_snapshot_retention_policy = @{
            num_snapshots = $ScheduleConfig.RemoteRetention
        }
        auto_suspend_timeout_secs = 0
        snapshot_type             = "CRASH_CONSISTENT"
    }
    
    # Build connectivity list - ONLY between index 0 and 1 (bidirectional)
    $connectivityList = @()
    
    # Forward: Primary (0) to Remote (1)
    $connectivityList += @{
        source_availability_zone_index      = 0
        destination_availability_zone_index = 1
        source_availability_zone_label      = "0"
        destination_availability_zone_label = "1"
        snapshot_schedule_list              = @($snapshotSchedule)
    }
    
    # Reverse: Remote (1) to Primary (0)
    $connectivityList += @{
        source_availability_zone_index      = 1
        destination_availability_zone_index = 0
        source_availability_zone_label      = "1"
        destination_availability_zone_label = "0"
        snapshot_schedule_list              = @($snapshotSchedule)
    }
    
    # Primary location list - index 0 is primary (contains all source clusters)
    $primaryLocationIndices = @(0)
    
    # Build the protection rule body
    $body = @{
        spec = @{
            name        = $PolicyName
            description = "Automated $ScheduleType backup policy - Created by DCES Core Service"
            resources   = @{
                start_time                          = ""
                ordered_availability_zone_list      = $orderedAZList
                availability_zone_connectivity_list = $connectivityList
                primary_location_list               = $primaryLocationIndices
                category_filter                     = $categoryFilter
            }
        }
        metadata = @{
            kind = "protection_rule"
        }
    }
    
    try {
        $response = Invoke-PrismAPI -Method POST -Endpoint "protection_rules" -Body $body
        
        # Check the immediate response state
        if ($response.status) {
            Write-LogMessage "Initial response state: $($response.status.state)" -Level Info
            if ($response.status.message_list) {
                Write-LogMessage "Initial messages:" -Level Info
                foreach ($msg in $response.status.message_list) {
                    Write-LogMessage "  - $($msg.message)" -Level Warning
                }
            }
        }
        
        $policyUUID = $response.metadata.uuid
        Write-LogMessage "Policy UUID: $policyUUID" -Level Info

        # Poll until state is COMPLETE, ERROR, or timeout (max 120 seconds)
        $maxWaitSecs  = 120
        $pollInterval = 10
        $elapsed      = 0
        $finalState   = ""

        Write-LogMessage "Waiting for policy to be processed (max ${maxWaitSecs}s)..." -Level Info

        do {
            Start-Sleep -Seconds $pollInterval
            $elapsed += $pollInterval

            try {
                $validationResponse = Invoke-PrismAPI -Method GET -Endpoint "protection_rules/$policyUUID"
                $finalState = $validationResponse.status.state
                Write-LogMessage "  [${elapsed}s] Policy state: $finalState" -Level Info
            }
            catch {
                if ($_ -match "404") {
                    if ($elapsed -le 30) {
                        Write-LogMessage "  [${elapsed}s] Policy not yet indexed (404) — retrying..." -Level Warning
                        $finalState = "PENDING"  # keep polling
                    } else {
                        Write-LogMessage "Policy rejected by Prism Central — still 404 after ${elapsed}s" -Level Error
                        throw "Policy creation rejected by Prism Central (404 after ${elapsed}s)"
                    }
                } else {
                    throw
                }
            }

        } while ($finalState -eq "PENDING" -or $finalState -eq "RUNNING" -and $elapsed -lt $maxWaitSecs)

        if ($finalState -eq "COMPLETE") {
            Write-LogMessage "Policy '$PolicyName' created successfully and is ACTIVE" -Level Success
            return $response
        }
        elseif ($elapsed -ge $maxWaitSecs -and ($finalState -eq "PENDING" -or $finalState -eq "RUNNING")) {
            # Still running after timeout - policy is being applied, not an error
            Write-LogMessage "Policy '$PolicyName' still in state '$finalState' after ${maxWaitSecs}s" -Level Warning
            Write-LogMessage "Policy was submitted successfully - Prism Central is still applying it in the background" -Level Warning
            return $response
        }
        else {
            Write-LogMessage "Policy '$PolicyName' ended in unexpected state: $finalState" -Level Error
            if ($validationResponse.status.message_list) {
                Write-LogMessage "Error messages from Prism Central:" -Level Error
                foreach ($msg in $validationResponse.status.message_list) {
                    Write-LogMessage "  - $($msg.message)" -Level Error
                }
            }
            throw "Policy creation failed with state: $finalState"
        }
    }
    catch {
        $errorDetail = ""
        if ($_.ErrorDetails) {
            $errorDetail = $_.ErrorDetails.Message
        }
        Write-LogMessage "FAILED to create policy: $PolicyName" -Level Error
        Write-LogMessage "Error: $($_.Exception.Message)" -Level Error
        if ($errorDetail) {
            Write-LogMessage "API response: $errorDetail" -Level Error
        }
        
        # Output the body that was sent for debugging
        Write-LogMessage "Policy configuration that was sent:" -Level Info
        Write-LogMessage ($body | ConvertTo-Json -Depth 10) -Level Info
        
        throw
    }
}

function Update-ProtectionPolicy {
    param(
        [object]$Policy,
        [string]$NewClusterUUID,
        [string]$NewClusterName,
        [array]$AvailabilityZones,
        [object]$NewCluster,
        [string]$CategoryValue = ""   # Expected category value e.g. "Daily-Backup"
    )
    
    Write-LogMessage "Updating policy '$($Policy.spec.name)' to include cluster: $NewClusterName..." -Level Info
    
    # Get full policy details
    $policyDetail = Invoke-PrismAPI -Method GET -Endpoint "protection_rules/$($Policy.metadata.uuid)"
    
    # Get the AZ list - should have 2 entries: Primary (index 0) and Remote (index 1)
    $azList = $policyDetail.spec.resources.ordered_availability_zone_list
    
    if ($azList.Count -ne 2) {
        Write-LogMessage "ERROR: Expected 2 AZ entries, found $($azList.Count)" -Level Error
        throw "Invalid policy structure"
    }
    
    # Check if cluster already exists in primary location (index 0)
    $primaryAZ = $azList[0]
    $remoteAZ  = $azList[1]
    
    # Build the set of currently-valid cluster UUIDs from PC so stale entries are dropped
    $liveClusterUUIDs = @(Get-AllClusters | ForEach-Object { $_.metadata.uuid })

    # Debug: Show existing clusters
    Write-LogMessage "Current policy structure:" -Level Info
    if ($primaryAZ.cluster_uuid_list) {
        Write-LogMessage "  Primary location has $($primaryAZ.cluster_uuid_list.Count) cluster(s):" -Level Info
        foreach ($uuid in $primaryAZ.cluster_uuid_list) {
            $isLive = if ($liveClusterUUIDs -contains $uuid) { 'live' } else { 'STALE - will be removed' }
            Write-LogMessage "    - $uuid ($isLive)" -Level Info
        }
    } elseif ($primaryAZ.cluster_uuid) {
        Write-LogMessage "  Primary location has single cluster: $($primaryAZ.cluster_uuid)" -Level Info
    } else {
        Write-LogMessage "  Primary location has NO clusters!" -Level Warning
    }
    
    # The primary AZ should have cluster_uuid_list (array)
    if ($primaryAZ.cluster_uuid_list -contains $NewClusterUUID) {
        Write-LogMessage "Cluster '$NewClusterName' already exists in policy '$($Policy.spec.name)'" -Level Info
        $clusterAlreadyPresent = $true
    } else {
        $clusterAlreadyPresent = $false
    }

    # --- Check category filter (only log, never recreate — categories are managed separately) ---
    $categoryNeedsUpdate = $false
    if ($CategoryValue -ne "") {
        $existingParams = $policyDetail.spec.resources.category_filter.params
        $existingCatValues = @()
        if ($existingParams -and $existingParams.PSObject.Properties["Backup"]) {
            $existingCatValues = @($existingParams.Backup)
        }

        if ($existingCatValues -contains $CategoryValue) {
            Write-LogMessage "  ✓ Category filter already set: Backup = $CategoryValue" -Level Success
        } else {
            Write-LogMessage "  ✗ Category filter missing or incorrect (expected Backup=$CategoryValue, found: '$($existingCatValues -join ', ')') - will fix" -Level Warning
            $categoryNeedsUpdate = $true
        }
    }

    # If cluster already present AND category is fine, nothing to do
    if ($clusterAlreadyPresent -and -not $categoryNeedsUpdate) {
        Write-LogMessage "  Policy '$($Policy.spec.name)' is already up to date - no changes needed" -Level Info
        return $policyDetail
    }
    
    Write-LogMessage "Adding cluster to policy..." -Level Info
    
    # Get Local AZ URL
    $localAZ    = $AvailabilityZones | Select-Object -First 1
    $localAZUrl = if ($localAZ) { $localAZ.spec.resources.management_url } else { "" }
    
    # Build updated primary cluster list:
    # Keep only UUIDs that are still live in PC, then add the new cluster.
    $updatedPrimaryClusterUUIDs = @()
    if ($primaryAZ.cluster_uuid_list) {
        $preserved = @($primaryAZ.cluster_uuid_list | Where-Object { $liveClusterUUIDs -contains $_ })
        $dropped   = @($primaryAZ.cluster_uuid_list | Where-Object { $liveClusterUUIDs -notcontains $_ })
        if ($dropped.Count -gt 0) {
            Write-LogMessage "  Removing $($dropped.Count) stale cluster UUID(s) no longer in PC: $($dropped -join ', ')" -Level Warning
        }
        $updatedPrimaryClusterUUIDs += $preserved
        Write-LogMessage "  Preserving $($preserved.Count) live existing cluster(s)" -Level Info
    }
    # Add the new cluster only if not already present
    if (-not $clusterAlreadyPresent) {
        $updatedPrimaryClusterUUIDs += $NewClusterUUID
        Write-LogMessage "  Total clusters after update: $($updatedPrimaryClusterUUIDs.Count)" -Level Info
    } else {
        Write-LogMessage "  Cluster already in list - only fixing category filter" -Level Info
    }
    
    # Rebuild AZ list with updated primary cluster list
    $newAZList = @()
    
    # Entry 0: Primary location with updated cluster_uuid_list (force array with @())
    $newAZList += @{
        availability_zone_url   = $localAZUrl
        availability_zone_label = "0"
        cluster_uuid_list       = @($updatedPrimaryClusterUUIDs)
        target_type             = "AOS_CLUSTER"
    }
    
    # Entry 1: Remote location (unchanged) with single cluster_uuid
    $newAZList += @{
        availability_zone_url   = $localAZUrl
        availability_zone_label = "1"
        cluster_uuid            = $remoteAZ.cluster_uuid
        target_type             = "AOS_CLUSTER"
    }
    
    # Primary location list remains [0]
    $newPrimaryLocations = @(0)
    
    # Build connectivity list - only between index 0 and 1
    $existingConnectivity = $policyDetail.spec.resources.availability_zone_connectivity_list
    $sampleSchedule       = $existingConnectivity[0].snapshot_schedule_list[0]
    
    $newConnectivityList = @()
    
    # Forward: Primary (0) to Remote (1)
    $newConnectivityList += @{
        source_availability_zone_index      = 0
        destination_availability_zone_index = 1
        source_availability_zone_label      = "0"
        destination_availability_zone_label = "1"
        snapshot_schedule_list              = @($sampleSchedule)
    }
    
    # Reverse: Remote (1) to Primary (0)
    $newConnectivityList += @{
        source_availability_zone_index      = 1
        destination_availability_zone_index = 0
        source_availability_zone_label      = "1"
        destination_availability_zone_label = "0"
        snapshot_schedule_list              = @($sampleSchedule)
    }
    
    # Update the policy with new structure
    $policyDetail.spec.resources.ordered_availability_zone_list      = $newAZList
    $policyDetail.spec.resources.primary_location_list               = $newPrimaryLocations
    $policyDetail.spec.resources.availability_zone_connectivity_list = $newConnectivityList

    # Apply correct category filter if needed
    if ($categoryNeedsUpdate -and $CategoryValue -ne "") {
        Write-LogMessage "  Applying category filter: Backup = $CategoryValue" -Level Info
        $policyDetail.spec.resources.category_filter = @{
            type   = "CATEGORIES_MATCH_ANY"
            params = @{ "Backup" = @($CategoryValue) }
        }
    }
    
    # Ensure metadata is properly formatted for PUT
    $updateBody = @{
        spec     = $policyDetail.spec
        metadata = @{
            kind         = $policyDetail.metadata.kind
            uuid         = $policyDetail.metadata.uuid
            spec_version = $policyDetail.metadata.spec_version
        }
    }
    
    # Update the policy
    try {
        $response = Invoke-PrismAPI -Method PUT -Endpoint "protection_rules/$($Policy.metadata.uuid)" -Body $updateBody
        Write-LogMessage "Successfully updated policy: $($Policy.spec.name)" -Level Success
        
        # Validate the update
        Start-Sleep -Seconds 3
        $validationResponse = Invoke-PrismAPI -Method GET -Endpoint "protection_rules/$($Policy.metadata.uuid)"
        
        if ($validationResponse.status.state -eq "COMPLETE") {
            Write-LogMessage "Policy update validated successfully" -Level Success
        } else {
            Write-LogMessage "Policy state after update: $($validationResponse.status.state)" -Level Warning
        }
        
        return $response
    }
    catch {
        $errorDetail = ""
        if ($_.ErrorDetails) {
            $errorDetail = $_.ErrorDetails.Message
        }
        Write-LogMessage "Failed to update policy: $($Policy.spec.name)" -Level Error
        Write-LogMessage "Error: $($_.Exception.Message)" -Level Error
        if ($errorDetail) {
            Write-LogMessage "API response: $errorDetail" -Level Error
        }
        throw
    }
}

#endregion

#region Main Script

function Main {
    param(
        [string]$PCAddress,
        [string]$PCUsername,
        [string]$PCPassword,
        [string]$ClusterName,
        [string]$ClusterVip = ""
    )
    
    # Initialize script variables
    $script:PrismCentralBaseURL = "https://${PCAddress}:9440/api/nutanix/v3"
    $script:Headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${PCUsername}:${PCPassword}"))
    }
    
    Write-LogMessage "Connecting to Prism Central: $PCAddress" -Level Info
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Nutanix Backup Policy Management Script" -Level Info
    Write-LogMessage "Developed and maintained by DCES core service" -Level Info
    Write-LogMessage "Version 2.0 - With Category Support" -Level Info
    Write-LogMessage "========================================" -Level Info
    Write-Host ""

    # --- Credential validation ---
    Write-LogMessage "Validating credentials against Prism Central..." -Level Info
    try {
        $testParams = @{
            Uri         = "https://${PCAddress}:9440/api/nutanix/v3/users/me"
            Method      = "GET"
            Headers     = $script:Headers
            ContentType = "application/json"
        }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $testParams.SkipCertificateCheck = $true }

        $testResponse = Invoke-RestMethod @testParams
        Write-LogMessage "  ✓ Login successful - connected as: $($testResponse.status.resources.display_name)" -Level Success
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $rawBody    = ""
        try { $rawBody = $_.ErrorDetails.Message } catch {}

        Write-LogMessage "  ✗ Login FAILED (HTTP $statusCode)" -Level Error

        if ($statusCode -eq 401) {
            Write-LogMessage "  Possible causes:" -Level Error
            Write-LogMessage "    1. Wrong password for user '$PCUsername'" -Level Error
            Write-LogMessage "    2. IP $PCAddress is a Prism ELEMENT cluster VIP, not Prism CENTRAL" -Level Error
            Write-LogMessage "    3. Account is locked or requires password change" -Level Error
            Write-LogMessage "  Please verify you can log in to https://${PCAddress}:9440 in a browser" -Level Error
        }
        if ($rawBody) {
            Write-LogMessage "  API response: $rawBody" -Level Error
        }
        throw "Authentication failed - cannot continue"
    }
    Write-Host ""

    # Step 1: Get all clusters
    $clusters = Get-AllClusters
    
    if ($clusters.Count -eq 0) {
        Write-LogMessage "No clusters found in Prism Central" -Level Error
        return
    }
    
    # Step 2: Find the cluster where PC is running
    $pcCluster = Get-PrismCentralCluster -Clusters $clusters
    
    if (-not $pcCluster) {
        Write-LogMessage "Cannot proceed without identifying PC cluster" -Level Error
        return
    }
    
    $pcClusterUUID = $pcCluster.metadata.uuid
    $pcClusterName = $pcCluster.spec.name
    
    # Step 3: Find the new cluster (handle duplicate names from stale registrations)
    $matchingClusters = @($clusters | Where-Object {
        $_.spec.name -eq $ClusterName -and
        $_.status.resources.config.service_list -notcontains "PRISM_CENTRAL"
    })

    if ($matchingClusters.Count -eq 0) {
        Write-LogMessage "Cluster '$ClusterName' not found in Prism Central" -Level Error
        Write-LogMessage "Available clusters: $(($clusters | Where-Object { $_.status.resources.config.service_list -notcontains 'PRISM_CENTRAL' } | ForEach-Object { $_.spec.name }) -join ', ')" -Level Info
        return
    }

    # Prefer the cluster whose VIP matches config (eliminates stale registrations)
    $newCluster = if ($matchingClusters.Count -gt 1 -and $ClusterVip) {
        $vipMatch = $matchingClusters | Where-Object {
            $_.spec.resources.network.external_ip  -eq $ClusterVip -or
            $_.status.resources.network.external_ip -eq $ClusterVip
        } | Sort-Object { $_.metadata.last_update_time } -Descending | Select-Object -First 1
        if ($vipMatch) {
            Write-LogMessage "Multiple clusters named '$ClusterName' found — selected by VIP ($ClusterVip) UUID: $($vipMatch.metadata.uuid)" -Level Warning
            $vipMatch
        } else {
            Write-LogMessage "Multiple clusters named '$ClusterName' found — no VIP match, using newest by last_update_time" -Level Warning
            $matchingClusters | Sort-Object { $_.metadata.last_update_time } -Descending | Select-Object -First 1
        }
    } else {
        $matchingClusters | Select-Object -First 1
    }

    $newClusterUUID = $newCluster.metadata.uuid
    Write-LogMessage "Found new cluster: $ClusterName (UUID: $newClusterUUID)" -Level Success
    
    # Step 4: Get existing protection policies to understand the structure
    $existingPolicies = Get-ProtectionPolicies
    
    # If there are existing policies, examine their structure
    if ($existingPolicies.Count -gt 0) {
        Write-Host ""
        Write-LogMessage "Examining existing policy structure for reference..." -Level Info
        $examplePolicy = $existingPolicies[0]
        
        if ($examplePolicy.spec.resources.ordered_availability_zone_list) {
            Write-LogMessage "Example policy AZ list:" -Level Info
            foreach ($az in $examplePolicy.spec.resources.ordered_availability_zone_list) {
                Write-LogMessage "  - Cluster UUID: $($az.cluster_uuid)" -Level Info
                Write-LogMessage "    AZ URL: $($az.availability_zone_url)" -Level Info
            }
        }
    }
    
    # Step 5: Get Availability Zones
    Write-Host ""
    $availabilityZones = Get-AvailabilityZones
    
    if ($availabilityZones.Count -eq 0) {
        Write-LogMessage "No Availability Zones found. Clusters must be registered as AZs before creating protection policies." -Level Error
        return
    }

    # Step 6: Check for Backup category and its values; create anything missing
    Write-Host ""
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Step 6: Checking Backup categories..." -Level Info
    Write-LogMessage "========================================" -Level Info

    # 6a: Check what already exists
    $backupCategory = Get-BackupCategoryValues

    # 6b: Create key and/or values that are missing
    $needsCreation = (-not $backupCategory.Found) -or
                     (-not $backupCategory.HasDaily) -or
                     (-not $backupCategory.HasWeekly) -or
                     (-not $backupCategory.HasMonthly)

    if ($needsCreation) {
        Write-LogMessage "  Some category items are missing - creating them now..." -Level Warning
        New-BackupCategoryIfMissing -CategoryStatus $backupCategory
    } else {
        Write-LogMessage "  All required Backup category values already exist" -Level Success
    }

    # All three values are now guaranteed to exist
    $policyCategoryMap = @{
        "Daily-Backup-Policy"   = "Daily-Backup"
        "Weekly-Backup-Policy"  = "Weekly-Backup"
        "Monthly-Backup-Policy" = "Monthly-Backup"
    }

    Write-Host ""
    Write-LogMessage "Category assignment summary:" -Level Info
    foreach ($policyName in $policyCategoryMap.Keys) {
        Write-LogMessage "  $policyName → Category: Backup = $($policyCategoryMap[$policyName])" -Level Success
    }
    
    # Step 7: Get existing protection policies
    $existingPolicies = Get-ProtectionPolicies
    
    # Define policy configurations
    $policyConfigs = @{
        "Daily-Backup-Policy" = @{
            ScheduleType    = "DAILY"
            RPO             = 86400   # 1 day in seconds
            LocalRetention  = 7
            RemoteRetention = 7
        }
        "Weekly-Backup-Policy" = @{
            ScheduleType    = "WEEKLY"
            RPO             = 604800  # 7 days in seconds
            LocalRetention  = 4
            RemoteRetention = 4
        }
        "Monthly-Backup-Policy" = @{
            ScheduleType    = "MONTHLY"
            RPO             = 2592000 # 30 days in seconds
            LocalRetention  = 1
            RemoteRetention = 6
        }
    }
    
    # Step 8: Check and create/update policies
    Write-Host ""
    Write-LogMessage "Processing backup policies..." -Level Info
    Write-Host ""
    
    foreach ($policyName in $policyConfigs.Keys) {
        $config          = $policyConfigs[$policyName]
        $existingPolicy  = $existingPolicies | Where-Object { $_.spec.name -eq $policyName }
        $catValue        = $policyCategoryMap[$policyName]
        
        if ($existingPolicy) {
            Write-LogMessage "Policy '$policyName' already exists" -Level Info
            try {
                Update-ProtectionPolicy `
                    -Policy          $existingPolicy `
                    -NewClusterUUID  $newClusterUUID `
                    -NewClusterName  $NewClusterName `
                    -AvailabilityZones $availabilityZones `
                    -NewCluster      $newCluster `
                    -CategoryValue   $catValue
            }
            catch {
                Write-LogMessage "Failed to update policy '$policyName'" -Level Error
                throw
            }
        }
        else {
            Write-LogMessage "Policy '$policyName' does not exist, creating..." -Level Info
            try {
                $null = New-ProtectionPolicy `
                    -PolicyName        $policyName `
                    -ScheduleType      $config.ScheduleType `
                    -ScheduleConfig    $config `
                    -RemoteCluster     $pcCluster `
                    -PrimaryClusters   @($newCluster) `
                    -AvailabilityZones $availabilityZones `
                    -CategoryValue     $catValue
            }
            catch {
                Write-LogMessage "Failed to create policy '$policyName' - STOPPING" -Level Error
                throw
            }
        }
        
        Write-Host ""
    }
    
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Backup policy management completed!" -Level Success
    Write-LogMessage "========================================" -Level Info
    Write-Host ""
    Write-LogMessage "Summary:" -Level Info
    Write-LogMessage "  - PC Cluster: $pcClusterName" -Level Info
    Write-LogMessage "  - New Cluster: $ClusterName" -Level Info
    Write-LogMessage "  - Policies processed: $($policyConfigs.Keys.Count)" -Level Info
    Write-Host ""
    
    # Validate all policies - poll each until COMPLETE or timeout
    Write-LogMessage "Waiting for all policies to reach COMPLETE state..." -Level Info

    $maxWaitSecs  = 120
    $pollInterval = 10

    foreach ($policyName in $policyConfigs.Keys) {
        $elapsed    = 0
        $finalState = ""
        $policyUUID = $null

        # Get the policy UUID first
        $allPolicies = Get-ProtectionPolicies
        $policy = $allPolicies | Where-Object { $_.spec.name -eq $policyName }
        if (-not $policy) {
            Write-LogMessage "  ✗ $policyName : Not found in Prism Central" -Level Warning
            continue
        }
        $policyUUID = $policy.metadata.uuid

        # Poll until COMPLETE or timeout.
        # Wrap in try/catch — after a cluster-list change Prism can temporarily
        # return 404 while re-keying the rule. Treat repeated 404 as "applied".
        $consecutive404 = 0; $maxConsecutive404 = 12   # up to 120s of 404s
        do {
            try {
                # Re-fetch UUID by name each iteration so a re-keyed rule is picked up
                $allPoliciesRefresh = Get-ProtectionPolicies
                $refreshedPolicy    = $allPoliciesRefresh | Where-Object { $_.spec.name -eq $policyName }
                if ($refreshedPolicy) { $policyUUID = $refreshedPolicy.metadata.uuid }

                $policyDetail = Invoke-PrismAPI -Method GET -Endpoint "protection_rules/$policyUUID"
                $finalState   = $policyDetail.status.state
                $consecutive404 = 0
            } catch {
                if ($_ -match '404') {
                    $consecutive404++
                    Write-LogMessage "  [${elapsed}s] $policyName : UUID not found (404) — Prism may be re-keying rule ($consecutive404/$maxConsecutive404)" -Level Warning
                    if ($consecutive404 -ge $maxConsecutive404) {
                        Write-LogMessage "  ⚠ $policyName : Still 404 after $($consecutive404 * $pollInterval)s — treating as applied" -Level Warning
                        break
                    }
                    $finalState = "PENDING"
                } else {
                    throw
                }
            }

            if ($finalState -eq "COMPLETE") { break }

            Write-LogMessage "  [${elapsed}s] $policyName : $finalState - waiting..." -Level Info
            Start-Sleep -Seconds $pollInterval
            $elapsed += $pollInterval

        } while ($elapsed -lt $maxWaitSecs)

        if ($finalState -eq "COMPLETE") {
            Write-LogMessage "  ✓ $policyName : Active" -Level Success
        } elseif ($elapsed -ge $maxWaitSecs) {
            Write-LogMessage "  ⚠ $policyName : Still '$finalState' after ${maxWaitSecs}s - Prism is still applying it (not an error)" -Level Warning
        } else {
            Write-LogMessage "  ✗ $policyName : $finalState" -Level Warning
            if ($policyDetail.status.message_list) {
                foreach ($msg in $policyDetail.status.message_list) {
                    Write-LogMessage "    - $($msg.message)" -Level Warning
                }
            }
        }
    }
}

# Execute main function
try {
    Main -PCAddress $PrismCentralIP -PCUsername $Username -PCPassword $Password -ClusterName $NewClusterName -ClusterVip $config.network.cluster_vip
}
catch {
    Write-LogMessage "Script execution failed: $($_.Exception.Message)" -Level Error
    exit 1
}

exit 0
#endregion
