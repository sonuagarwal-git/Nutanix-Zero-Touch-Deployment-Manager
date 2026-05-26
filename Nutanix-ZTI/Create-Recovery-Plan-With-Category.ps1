<#
.SYNOPSIS
    Manage Prism Central Failover Recovery Plan for cross-site replication

.DESCRIPTION
    This script connects to Prism Central and creates a dedicated Failover Recovery Plan
    for each source cluster. Recovery plan name is automatically set to:
        {ClusterName}-Recovery-Plan

    - Source (primary) location : cluster name provided via -NewClusterName
    - Target (recovery) location: cluster hosting the Prism Central VM (auto-detected)
    - Category filter applied in stage: Failover = Failover (created if missing)
    - Network mapping: configures VLAN and IP pool for each site (no per-VM IP assignments)
    - Each cluster gets its OWN recovery plan - plans are never shared across clusters
    - If a plan for this cluster already exists: reports it and exits cleanly (idempotent)

.PARAMETER ConfigFile
    Path to the cluster JSON config file.
    Source network is taken from the first entry of 'production_vlans'.
    Recovery network is taken from 'hub_production'.
    Optional when all individual parameters are supplied directly.

.PARAMETER PrismCentralIP
    Prism Central IP or FQDN. Overrides the value from ConfigFile if both are provided.

.PARAMETER Username
    Prism Central admin username.

.PARAMETER Password
    Prism Central admin password.

.PARAMETER ClusterName
    Name of the source cluster.

.PARAMETER SourceNetworkName
    Name of the source (primary site) network/subnet.

.PARAMETER SourceGateway
    Gateway IP of the source network.

.PARAMETER SourcePrefixLength
    Prefix length of the source network (e.g. 24).

.PARAMETER SourceStartIP
    Start of the source IP pool.

.PARAMETER SourceEndIP
    End of the source IP pool.

.PARAMETER RecoveryNetworkName
    Name of the recovery (hub/target site) network/subnet.

.PARAMETER RecoveryGateway
    Gateway IP of the recovery network.

.PARAMETER RecoveryPrefixLength
    Prefix length of the recovery network (e.g. 24).

.PARAMETER RecoveryStartIP
    Start of the recovery IP pool.

.PARAMETER RecoveryEndIP
    End of the recovery IP pool.

.EXAMPLE
    # Create recovery plan using config file
    .\Manage-Recovery-Plan-With-Category.ps1 -ConfigFile ".\Configs\my-cluster.json"

.EXAMPLE
    # Run without a config file — supply all values manually
    .\Create-Recovery-Plan-With-Category.ps1 -PrismCentralIP "10.0.1.20" `
        -Username "admin" -Password "MyPass!" -ClusterName "my-cluster" `
        -SourceNetworkName "prod-vlan100" -SourceGateway "10.0.100.1" -SourcePrefixLength 24 `
        -SourceStartIP "10.0.100.50" -SourceEndIP "10.0.100.100" `
        -RecoveryNetworkName "hub-prod-vlan200" -RecoveryGateway "10.0.200.1" -RecoveryPrefixLength 24 `
        -RecoveryStartIP "10.0.200.50" -RecoveryEndIP "10.0.200.100"

.NOTES
    Author: Sonu Agarwal
    Date: March 27, 2026
    Version: 2.0 - Per-cluster recovery plans (one plan per source cluster)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$PrismCentralIP,

    [Parameter(Mandatory = $false)]
    [string]$Username,

    [Parameter(Mandatory = $false)]
    [string]$Password,

    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$SourceNetworkName,

    [Parameter(Mandatory = $false)]
    [string]$SourceGateway,

    [Parameter(Mandatory = $false)]
    [int]$SourcePrefixLength,

    [Parameter(Mandatory = $false)]
    [string]$SourceStartIP,

    [Parameter(Mandatory = $false)]
    [string]$SourceEndIP,

    [Parameter(Mandatory = $false)]
    [string]$RecoveryNetworkName,

    [Parameter(Mandatory = $false)]
    [string]$RecoveryGateway,

    [Parameter(Mandatory = $false)]
    [int]$RecoveryPrefixLength,

    [Parameter(Mandatory = $false)]
    [string]$RecoveryStartIP,

    [Parameter(Mandatory = $false)]
    [string]$RecoveryEndIP
)

# Load config
if ($ConfigFile) {
    $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    if (-not $PrismCentralIP)    { $PrismCentralIP    = $config.prism_central.ip }
    if (-not $Username)          { $Username          = $config.prism_central.username }
    if (-not $Password)          { $Password          = $config.prism_central.password }
    if (-not $ClusterName)       { $ClusterName       = $config.clusterName }
    $srcVlan = $config.production_vlans[0]
    $hubVlan = $config.hub_production
    if (-not $SourceNetworkName)   { $SourceNetworkName   = $srcVlan.subnet_name }
    if (-not $SourceGateway)       { $SourceGateway       = $srcVlan.gateway }
    if (-not $SourcePrefixLength)  { $SourcePrefixLength  = [int]$srcVlan.prefix_length }
    if (-not $SourceStartIP)       { $SourceStartIP       = $srcVlan.ip_pool_start }
    if (-not $SourceEndIP)         { $SourceEndIP         = $srcVlan.ip_pool_end }
    if (-not $RecoveryNetworkName) { $RecoveryNetworkName = $hubVlan.subnet_name }
    if (-not $RecoveryGateway)     { $RecoveryGateway     = $hubVlan.gateway }
    if (-not $RecoveryPrefixLength){ $RecoveryPrefixLength= [int]$hubVlan.prefix_length }
    if (-not $RecoveryStartIP)     { $RecoveryStartIP     = $hubVlan.ip_pool_start }
    if (-not $RecoveryEndIP)       { $RecoveryEndIP       = $hubVlan.ip_pool_end }
} elseif (-not $PrismCentralIP -or -not $Username -or -not $Password -or -not $ClusterName) {
    Write-Host "ERROR: Provide either -ConfigFile or all of: -PrismCentralIP, -Username, -Password, -ClusterName (plus network params)." -ForegroundColor Red
    exit 1
}

$NewClusterName = $ClusterName

if (-not $PrismCentralIP) {
    Write-Host "ERROR: 'prism_central.ip' not found in config file: $ConfigFile" -ForegroundColor Red
    exit 1
}
if (-not $NewClusterName) {
    Write-Host "ERROR: 'clusterName' not found in config file: $ConfigFile" -ForegroundColor Red
    exit 1
}
if (-not $SourceNetworkName) {
    Write-Host "ERROR: 'production_vlans[0].subnet_name' not found in config file: $ConfigFile" -ForegroundColor Red
    exit 1
}

# ── Constants ──────────────────────────────────────────────────────────────────
$CATEGORY_KEY   = "Failover"
$CATEGORY_VALUE = "Failover"

# ── Certificate bypass (PS5) ───────────────────────────────────────────────────
if ($PSVersionTable.PSVersion.Major -lt 6) {
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
        Add-Type @"
        using System.Net;
        using System.Net.Security;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) { return true; }
        }
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# ── Script-level variables ─────────────────────────────────────────────────────
$script:PrismCentralBaseURL = ""
$script:Headers             = @{}

#region Helper Functions

function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'Cyan'   }
        'Success' { 'Green'  }
        'Warning' { 'Yellow' }
        'Error'   { 'Red'    }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Invoke-PrismAPI {
    param(
        [string]$Method   = "GET",
        [string]$Endpoint,
        [object]$Body     = $null
    )
    $uri = "$script:PrismCentralBaseURL/$Endpoint"
    try {
        $params = @{
            Uri         = $uri
            Method      = $Method
            Headers     = $script:Headers
            ContentType = "application/json"
        }
        if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 15 -Compress) }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }
        return Invoke-RestMethod @params
    }
    catch {
        Write-LogMessage "API Error [$Method $Endpoint]: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Get-AllClusters {
    Write-LogMessage "Retrieving all clusters from Prism Central..." -Level Info
    $response     = Invoke-PrismAPI -Method POST -Endpoint "clusters/list" -Body @{ kind = "cluster"; length = 500 }
    $realClusters = $response.entities | Where-Object {
        $_.spec.name -notmatch "^Unnamed$" -and
        $_.status.resources.config.service_list -notcontains "PRISM_CENTRAL"
    }
    Write-LogMessage "Found $($realClusters.Count) Nutanix cluster(s)" -Level Success
    foreach ($c in $realClusters) { Write-LogMessage "  - $($c.spec.name)" -Level Info }
    return $response.entities
}

function Get-PrismCentralCluster {
    param([array]$Clusters)
    Write-LogMessage "Identifying cluster hosting Prism Central VM..." -Level Info

    $pcEntry = $Clusters | Where-Object { $_.status.resources.config.service_list -contains "PRISM_CENTRAL" }
    if (-not $pcEntry) {
        Write-LogMessage "Could not find PC entry in clusters list" -Level Error
        Write-LogMessage "Could not determine which cluster hosts Prism Central" -Level Error
        return $null
    }

    $pcVMName = $pcEntry.spec.name
    Write-LogMessage "PC VM name from cluster list: $pcVMName" -Level Info

    # Helper: follow a VM's cluster_reference back to the real cluster entity
    function Resolve-ClusterFromVM {
        param([object]$pcVM)
        Write-LogMessage "  Resolving cluster for VM: $($pcVM.spec.name) (UUID: $($pcVM.metadata.uuid))" -Level Info
        $detail = Invoke-PrismAPI -Method GET -Endpoint "vms/$($pcVM.metadata.uuid)"
        $hostClusterUUID = $null
        if ($detail.spec.cluster_reference)        { $hostClusterUUID = $detail.spec.cluster_reference.uuid }
        elseif ($detail.status.cluster_reference)  { $hostClusterUUID = $detail.status.cluster_reference.uuid }

        if (-not $hostClusterUUID) {
            Write-LogMessage "  Could not extract cluster_reference from VM" -Level Warning
            return $null
        }
        $hostCluster = $Clusters | Where-Object {
            $_.metadata.uuid -eq $hostClusterUUID -and
            $_.status.resources.config.service_list -notcontains "PRISM_CENTRAL"
        }
        if ($hostCluster) {
            Write-LogMessage "Prism Central is running on cluster: $($hostCluster.spec.name)" -Level Success
            return $hostCluster
        }
        Write-LogMessage "  Cluster UUID $hostClusterUUID not found in cluster list" -Level Warning
        return $null
    }

    # ── Primary: subnet match on NTNX-*-PCVM-* VMs ───────────────────────────
    # PC VIP and PC VM IPs share the same /24 subnet. VM names follow:
    # NTNX-<vm-ip-dashes>-PCVM-<suffix>  e.g. NTNX-10-0-66-26-PCVM-1778...
    # Match on first 3 octets so .26/.27/.28 are all found when VIP is .25
    try {
        $pcIp    = $PrismCentralIP
        $subnet3 = ($pcIp -split '\.')[0..2] -join '-'   # e.g. "10-0-66"

        Write-LogMessage "Searching for PCVM VMs in subnet '$subnet3.*'..." -Level Info

        $body     = @{ kind = "vm"; length = 500 }
        $allPCVMs = Invoke-PrismAPI -Method POST -Endpoint "vms/list" -Body $body

        Write-LogMessage "  Found $($allPCVMs.entities.Count) total VM(s), filtering for PCVM in subnet '$subnet3'..." -Level Info

        $subnetMatches = $allPCVMs.entities | Where-Object {
            $_.spec.name -match "PCVM" -and $_.spec.name -match [regex]::Escape($subnet3)
        }

        if ($subnetMatches) {
            Write-LogMessage "  $($subnetMatches.Count) VM(s) match subnet '$subnet3'" -Level Info
            foreach ($vm in $subnetMatches) {
                $result = Resolve-ClusterFromVM -pcVM $vm
                if ($result) { return $result }
            }
        } else {
            Write-LogMessage "  No PCVM VMs matched subnet '$subnet3'" -Level Warning
        }
    } catch {
        Write-LogMessage "Subnet-based PCVM search failed: $($_.Exception.Message)" -Level Warning
    }

    # ── Fallback: exact VM name match ─────────────────────────────────────────
    try {
        Write-LogMessage "Falling back to exact name search for '$pcVMName'..." -Level Info
        $body             = @{ kind = "vm"; filter = "vm_name==$pcVMName"; length = 10 }
        $vmSearchResponse = Invoke-PrismAPI -Method POST -Endpoint "vms/list" -Body $body
        if ($vmSearchResponse.entities.Count -gt 0) {
            $result = Resolve-ClusterFromVM -pcVM $vmSearchResponse.entities[0]
            if ($result) { return $result }
        } else {
            Write-LogMessage "  Exact name search returned no results" -Level Warning
        }
    } catch {
        Write-LogMessage "Exact name search failed: $($_.Exception.Message)" -Level Warning
    }

    # ── Last resort: description tag 'NutanixPrismCentral' ───────────────────
    try {
        Write-LogMessage "Last resort: searching for VM with description 'NutanixPrismCentral'..." -Level Info
        $body     = @{ kind = "vm"; length = 500 }
        $allVMs   = Invoke-PrismAPI -Method POST -Endpoint "vms/list" -Body $body
        $pcByDesc = $allVMs.entities | Where-Object {
            $_.spec.description   -match "NutanixPrismCentral" -or
            $_.status.description -match "NutanixPrismCentral"
        } | Select-Object -First 1

        if ($pcByDesc) {
            Write-LogMessage "Found PC VM by description: $($pcByDesc.spec.name)" -Level Info
            $result = Resolve-ClusterFromVM -pcVM $pcByDesc
            if ($result) { return $result }
        } else {
            Write-LogMessage "  No VM found with description 'NutanixPrismCentral'" -Level Warning
        }
    } catch {
        Write-LogMessage "Description-based VM search failed: $($_.Exception.Message)" -Level Warning
    }

    Write-LogMessage "Could not determine which cluster hosts Prism Central" -Level Error
    return $null
}

function Get-LocalAvailabilityZoneUUID {
    Write-LogMessage "Retrieving Availability Zones..." -Level Info
    $response = Invoke-PrismAPI -Method POST -Endpoint "availability_zones/list" -Body @{ kind = "availability_zone"; length = 500 }
    Write-LogMessage "Found $($response.entities.Count) Availability Zone(s)" -Level Success
    foreach ($az in $response.entities) {
        Write-LogMessage "  - metadata.uuid: $($az.metadata.uuid) | name: '$($az.spec.resources.name)' | management_url: '$($az.spec.resources.management_url)'" -Level Info
    }

    # Use the first (local) AZ — availability_zone_url in recovery plans must be the management_url value
    $localAZ = $response.entities | Select-Object -First 1
    $azURL   = $localAZ.spec.resources.management_url
    if (-not $azURL) { $azURL = $localAZ.metadata.uuid }  # fallback if management_url is empty

    Write-LogMessage "Using AZ URL (for recovery plan bodies): $azURL" -Level Success
    return $azURL
}

#region Category Functions

function Get-FailoverCategoryStatus {
    Write-LogMessage "Checking for '$CATEGORY_KEY' category..." -Level Info
    $result = @{ Found = $false; HasFailover = $false }

    try {
        $keysResp = Invoke-PrismAPI -Method POST -Endpoint "categories/list" -Body @{ kind = "category"; length = 500 }
        if ($keysResp.entities | Where-Object { $_.name -eq $CATEGORY_KEY }) {
            Write-LogMessage "  ✓ '$CATEGORY_KEY' key found" -Level Success
            $result.Found = $true
        } else {
            Write-LogMessage "  '$CATEGORY_KEY' key NOT found" -Level Warning
            return $result
        }
    }
    catch { Write-LogMessage "Error checking category keys: $($_.Exception.Message)" -Level Error; throw }

    try {
        $valsResp = Invoke-PrismAPI -Method POST -Endpoint "categories/$CATEGORY_KEY/list" -Body @{ kind = "category"; length = 500 }
        $values   = @($valsResp.entities | ForEach-Object { $_.value })
        Write-LogMessage "  '$CATEGORY_KEY' values: $($values -join ', ')" -Level Info
        if ($values -contains $CATEGORY_VALUE) {
            Write-LogMessage "  ✓ Value '$CATEGORY_VALUE' found" -Level Success
            $result.HasFailover = $true
        } else {
            Write-LogMessage "  ✗ Value '$CATEGORY_VALUE' NOT found" -Level Warning
        }
    }
    catch { Write-LogMessage "Error checking category values: $($_.Exception.Message)" -Level Error; throw }

    return $result
}

function New-FailoverCategoryIfMissing {
    param([hashtable]$CategoryStatus)
    if (-not $CategoryStatus.Found) {
        Write-LogMessage "  Creating '$CATEGORY_KEY' key..." -Level Warning
        Invoke-PrismAPI -Method PUT -Endpoint "categories/$CATEGORY_KEY" -Body @{
            name        = $CATEGORY_KEY
            description = "Failover category"
        } | Out-Null
        Write-LogMessage "  ✓ '$CATEGORY_KEY' key created" -Level Success
    }
    if (-not $CategoryStatus.HasFailover) {
        Write-LogMessage "  Creating value '$CATEGORY_VALUE'..." -Level Warning
        Invoke-PrismAPI -Method PUT -Endpoint "categories/$CATEGORY_KEY/$CATEGORY_VALUE" -Body @{
            value       = $CATEGORY_VALUE
            description = "Failover replication"
        } | Out-Null
        Write-LogMessage "  ✓ Value '$CATEGORY_VALUE' created" -Level Success
    }
}

#endregion

function Get-RecoveryPlans {
    Write-LogMessage "Retrieving existing recovery plans..." -Level Info
    $response = Invoke-PrismAPI -Method POST -Endpoint "recovery_plans/list" -Body @{ kind = "recovery_plan"; length = 500 }
    Write-LogMessage "Found $($response.entities.Count) recovery plan(s)" -Level Info
    return $response.entities
}

function Build-SubnetEntry {
    param([string]$Gateway, [int]$Prefix, [string]$StartIP, [string]$EndIP)
    return @{
        external_connectivity_state = "DISABLED"
        gateway_ip                  = $Gateway
        prefix_length               = $Prefix
        subnet_range                = @{
            start_ip_address = $StartIP
            end_ip_address   = $EndIP
        }
    }
}

function Build-NetworkDef {
    param([string]$NetworkName, [string]$Gateway, [int]$Prefix, [string]$StartIP, [string]$EndIP)
    return @{
        name        = $NetworkName
        subnet_list = @(Build-SubnetEntry -Gateway $Gateway -Prefix $Prefix -StartIP $StartIP -EndIP $EndIP)
    }
}

function New-FailoverRecoveryPlan {
    param(
        [object]$SourceCluster,
        [object]$RecoveryCluster,
        [string]$AZUuid,
        [string]$PlanName,
        # Source network
        [string]$SrcNetName, [string]$SrcGateway, [int]$SrcPrefix, [string]$SrcStart, [string]$SrcEnd,
        # Recovery network
        [string]$RecNetName, [string]$RecGateway, [int]$RecPrefix, [string]$RecStart, [string]$RecEnd
    )

    Write-LogMessage "Creating recovery plan: $PlanName..." -Level Info
    Write-LogMessage "  Source   : $($SourceCluster.spec.name) — Network: $SrcNetName ($SrcGateway/$SrcPrefix)" -Level Info
    Write-LogMessage "  Recovery : $($RecoveryCluster.spec.name) — Network: $RecNetName ($RecGateway/$RecPrefix)" -Level Info

    $stageUUID       = [System.Guid]::NewGuid().ToString()
    $srcNet          = Build-NetworkDef -NetworkName $SrcNetName -Gateway $SrcGateway -Prefix $SrcPrefix -StartIP $SrcStart -EndIP $SrcEnd
    $recNet          = Build-NetworkDef -NetworkName $RecNetName -Gateway $RecGateway -Prefix $RecPrefix -StartIP $RecStart -EndIP $RecEnd
    $srcClusterRef   = @{ kind = "cluster"; name = $SourceCluster.spec.name;   uuid = $SourceCluster.metadata.uuid }
    $recClusterRef   = @{ kind = "cluster"; name = $RecoveryCluster.spec.name; uuid = $RecoveryCluster.metadata.uuid }

    $body = @{
        spec     = @{
            name        = $PlanName
            description = "Failover Recovery Plan for cross-site replication"
            resources   = @{
                stage_list = @(
                    @{
                        stage_uuid      = $stageUUID
                        delay_time_secs = 0
                        stage_work      = @{
                            recover_entities = @{
                                entity_info_list = @(
                                    @{
                                        categories = @{ $CATEGORY_KEY = $CATEGORY_VALUE }
                                    }
                                )
                            }
                        }
                    }
                )
                parameters = @{
                    primary_location_index       = 0
                    data_service_ip_mapping_list = @()
                    availability_zone_list       = @(
                        @{
                            availability_zone_url  = $AZUuid
                            cluster_reference_list = @($srcClusterRef)
                        },
                        @{
                            availability_zone_url  = $AZUuid
                            cluster_reference_list = @($recClusterRef)
                        }
                    )
                    network_mapping_list = @(
                        @{
                            is_ip_mapping_enabled                  = $true
                            availability_zone_network_mapping_list = @(
                                @{
                                    availability_zone_url  = $AZUuid
                                    cluster_reference_list = @($srcClusterRef)
                                    recovery_network       = $srcNet
                                    test_network           = $srcNet
                                },
                                @{
                                    availability_zone_url  = $AZUuid
                                    cluster_reference_list = @($recClusterRef)
                                    recovery_network       = $recNet
                                    test_network           = $recNet
                                }
                            )
                        }
                    )
                }
            }
        }
        metadata = @{ kind = "recovery_plan" }
    }

    try {
        $response = Invoke-PrismAPI -Method POST -Endpoint "recovery_plans" -Body $body
        $planUUID = $response.metadata.uuid
        Write-LogMessage "Recovery plan UUID: $planUUID" -Level Info

        # Poll for completion
        $maxWait  = 120; $interval = 10; $elapsed = 0; $state = ""
        Write-LogMessage "Waiting for plan to be processed (max ${maxWait}s)..." -Level Info
        do {
            Start-Sleep -Seconds $interval
            $elapsed += $interval
            try {
                $check = Invoke-PrismAPI -Method GET -Endpoint "recovery_plans/$planUUID"
                $state = $check.status.state
                Write-LogMessage "  [${elapsed}s] State: $state" -Level Info
            }
            catch {
                if ($_ -match "404" -and $elapsed -lt 30) {
                    Write-LogMessage "  [${elapsed}s] Plan not yet indexed (404) - retrying..." -Level Warning
                    $state = "PENDING"  # keep loop alive — continue re-checks while condition
                } elseif ($_ -match "404") {
                    throw "Plan not found after ${elapsed}s - likely rejected by Prism Central (invalid body)"
                } else {
                    throw
                }
            }
        } while (($state -eq "PENDING" -or $state -eq "RUNNING") -and $elapsed -lt $maxWait)

        if ($state -eq "COMPLETE") {
            Write-LogMessage "Recovery plan '$PlanName' created successfully and is ACTIVE" -Level Success
        } elseif ($elapsed -ge $maxWait -and ($state -eq "PENDING" -or $state -eq "RUNNING")) {
            Write-LogMessage "Plan still in '$state' after ${maxWait}s - Prism is still applying (not an error)" -Level Warning
        } else {
            Write-LogMessage "Plan ended in unexpected state: $state" -Level Error
            throw "Recovery plan creation failed with state: $state"
        }
        return $response
    }
    catch {
        $detail = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { "" }
        Write-LogMessage "FAILED to create recovery plan: $($_.Exception.Message)" -Level Error
        if ($detail) { Write-LogMessage "API response: $detail" -Level Error }
        Write-LogMessage "Plan body sent:" -Level Info
        Write-LogMessage ($body | ConvertTo-Json -Depth 15) -Level Info
        throw
    }
}

function Update-FailoverRecoveryPlan {
    param(
        [object]$Plan,
        [object]$NewSourceCluster,
        [string]$AZUuid,
        [string]$SrcNetName, [string]$SrcGateway, [int]$SrcPrefix, [string]$SrcStart, [string]$SrcEnd
    )

    Write-LogMessage "Updating '$($Plan.spec.name)' to include cluster: $($NewSourceCluster.spec.name)..." -Level Info

    $planDetail = Invoke-PrismAPI -Method GET -Endpoint "recovery_plans/$($Plan.metadata.uuid)"
    $params     = $planDetail.spec.resources.parameters

    # ── Check availability_zone_list[0] ────────────────────────────────────────
    $az0          = $params.availability_zone_list[0]
    $existingUUIDs = @($az0.cluster_reference_list | ForEach-Object { $_.uuid })
    $alreadyInAZ  = $existingUUIDs -contains $NewSourceCluster.metadata.uuid

    # ── Check network_mapping entry ────────────────────────────────────────────
    $netMaps      = $params.network_mapping_list[0].availability_zone_network_mapping_list
    $alreadyInNet = ($netMaps | Where-Object {
        $_.cluster_reference_list | Where-Object { $_.uuid -eq $NewSourceCluster.metadata.uuid }
    }).Count -gt 0

    if ($alreadyInAZ -and $alreadyInNet) {
        Write-LogMessage "  Cluster '$($NewSourceCluster.spec.name)' already present - no changes needed" -Level Info
        return $planDetail
    }

    $newClusterRef = @{ kind = "cluster"; name = $NewSourceCluster.spec.name; uuid = $NewSourceCluster.metadata.uuid }
    $srcNet        = Build-NetworkDef -NetworkName $SrcNetName -Gateway $SrcGateway -Prefix $SrcPrefix -StartIP $SrcStart -EndIP $SrcEnd

    # ── Add to availability_zone_list[0] ──────────────────────────────────────
    if (-not $alreadyInAZ) {
        Write-LogMessage "  Adding to availability_zone_list[0]..." -Level Info
        $updatedRefs = @($az0.cluster_reference_list) + @($newClusterRef)
        $params.availability_zone_list[0].cluster_reference_list = $updatedRefs
        Write-LogMessage "  Cluster count at primary AZ: $($updatedRefs.Count)" -Level Info
    }

    # ── Add network mapping entry (insert before last/recovery entry) ──────────
    if (-not $alreadyInNet) {
        Write-LogMessage "  Adding network mapping for: $($NewSourceCluster.spec.name) → $SrcNetName" -Level Info
        $newNetEntry = @{
            availability_zone_url  = $AZUuid
            cluster_reference_list = @($newClusterRef)
            recovery_network       = $srcNet
            test_network           = $srcNet
        }
        $allNetMaps   = @($netMaps)
        $lastEntry    = $allNetMaps[-1]
        $otherEntries = $allNetMaps[0..($allNetMaps.Count - 2)]
        $params.network_mapping_list[0].availability_zone_network_mapping_list = @($otherEntries) + @($newNetEntry) + @($lastEntry)
    }

    $updateBody = @{
        spec     = $planDetail.spec
        metadata = @{
            kind         = $planDetail.metadata.kind
            uuid         = $planDetail.metadata.uuid
            spec_version = $planDetail.metadata.spec_version
        }
    }

    try {
        $response = Invoke-PrismAPI -Method PUT -Endpoint "recovery_plans/$($Plan.metadata.uuid)" -Body $updateBody
        Write-LogMessage "Successfully updated recovery plan: $($Plan.spec.name)" -Level Success

        Start-Sleep -Seconds 5
        $check = Invoke-PrismAPI -Method GET -Endpoint "recovery_plans/$($Plan.metadata.uuid)"
        Write-LogMessage "Plan state after update: $($check.status.state)" -Level Info
        return $response
    }
    catch {
        $detail = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { "" }
        Write-LogMessage "Failed to update plan: $($_.Exception.Message)" -Level Error
        if ($detail) { Write-LogMessage "API response: $detail" -Level Error }
        throw
    }
}

function Wait-ForRecoveryPlanComplete {
    param([string]$PlanUUID, [string]$PlanName)
    $maxWait  = 120; $interval = 10; $elapsed = 0; $state = ""
    Write-LogMessage "Final check: waiting for '$PlanName' to reach COMPLETE (max ${maxWait}s)..." -Level Info
    do {
        $check  = Invoke-PrismAPI -Method GET -Endpoint "recovery_plans/$PlanUUID"
        $state  = $check.status.state
        if ($state -eq "COMPLETE") { break }
        Write-LogMessage "  [${elapsed}s] $PlanName : $state" -Level Info
        Start-Sleep -Seconds $interval
        $elapsed += $interval
    } while ($elapsed -lt $maxWait)

    if ($state -eq "COMPLETE") {
        Write-LogMessage "  ✓ $PlanName : Active" -Level Success
    } elseif ($elapsed -ge $maxWait) {
        Write-LogMessage "  ⚠ $PlanName : Still '$state' after ${maxWait}s - Prism is still applying (not an error)" -Level Warning
    } else {
        Write-LogMessage "  ✗ $PlanName : $state" -Level Warning
        if ($check.status.message_list) {
            foreach ($msg in $check.status.message_list) { Write-LogMessage "    - $($msg.message)" -Level Warning }
        }
    }
}

#endregion

#region Main Script

function Main {
    param(
        [string]$PCAddress, [string]$PCUsername, [string]$PCPassword,
        [string]$ClusterName,
        [string]$ClusterVip = "",
        [string]$SrcNetName, [string]$SrcGateway, [int]$SrcPrefix, [string]$SrcStart, [string]$SrcEnd,
        [string]$RecNetName, [string]$RecGateway, [int]$RecPrefix, [string]$RecStart, [string]$RecEnd
    )

    # Plan name is always per-cluster
    $PlanName = "$ClusterName-Recovery-Plan"

    $script:PrismCentralBaseURL = "https://${PCAddress}:9440/api/nutanix/v3"
    $script:Headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${PCUsername}:${PCPassword}"))
    }

    Write-LogMessage "Connecting to Prism Central: $PCAddress" -Level Info
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Failover Recovery Plan Management" -Level Info
    Write-LogMessage "Version 1.0 - Cross-site replication" -Level Info
    Write-LogMessage "========================================" -Level Info
    Write-Host ""

    # ── Credential validation ──────────────────────────────────────────────────
    Write-LogMessage "Validating credentials..." -Level Info
    try {
        $testParams = @{
            Uri         = "https://${PCAddress}:9440/api/nutanix/v3/users/me"
            Method      = "GET"
            Headers     = $script:Headers
            ContentType = "application/json"
        }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $testParams.SkipCertificateCheck = $true }
        $me = Invoke-RestMethod @testParams
        Write-LogMessage "  ✓ Login successful - connected as: $($me.status.resources.display_name)" -Level Success
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-LogMessage "  ✗ Login FAILED (HTTP $code)" -Level Error
        if ($code -eq 401) { Write-LogMessage "  Check: password and PC IP (not Prism Element VIP)" -Level Error }
        throw "Authentication failed"
    }
    Write-Host ""

    # ── Step 1: Get all clusters ───────────────────────────────────────────────
    $clusters = Get-AllClusters
    if ($clusters.Count -eq 0) { Write-LogMessage "No clusters found" -Level Error; return }

    # ── Step 2: Find recovery/target cluster (hosts PC VM) ────────────────────
    $pcCluster = Get-PrismCentralCluster -Clusters $clusters
    if (-not $pcCluster) { Write-LogMessage "Cannot identify PC cluster - stopping" -Level Error; return }

    # ── Step 3: Find source cluster, deduplicate stale registrations ─────────────
    $matchingClusters = @($clusters | Where-Object {
        $_.spec.name -eq $ClusterName -and
        $_.status.resources.config.service_list -notcontains "PRISM_CENTRAL"
    })

    if ($matchingClusters.Count -eq 0) {
        $available = ($clusters | Where-Object { $_.status.resources.config.service_list -notcontains "PRISM_CENTRAL" }).spec.name -join ", "
        Write-LogMessage "Cluster '$ClusterName' not found. Available: $available" -Level Error
        return
    }

    $srcCluster = if ($matchingClusters.Count -gt 1 -and $ClusterVip) {
        $vipMatch = $matchingClusters | Where-Object {
            $_.spec.resources.network.external_ip   -eq $ClusterVip -or
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

    Write-LogMessage "Source cluster   : $ClusterName (UUID: $($srcCluster.metadata.uuid))" -Level Success
    Write-LogMessage "Recovery cluster : $($pcCluster.spec.name) (UUID: $($pcCluster.metadata.uuid))" -Level Info

    # ── Step 4: Get local AZ UUID ─────────────────────────────────────────────
    Write-Host ""
    $azUuid = Get-LocalAvailabilityZoneUUID
    if (-not $azUuid) { Write-LogMessage "No AZ found - ensure clusters are registered in Prism Central" -Level Error; return }
    Write-LogMessage "AZ URL to use in plan bodies: $azUuid" -Level Info

    # ── Step 5: Ensure Failover category ──────────────────────────────────────
    Write-Host ""
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Step 5: Checking Failover category..." -Level Info
    Write-LogMessage "========================================" -Level Info
    $catStatus = Get-FailoverCategoryStatus
    if ((-not $catStatus.Found) -or (-not $catStatus.HasFailover)) {
        Write-LogMessage "  Missing category items - creating now..." -Level Warning
        New-FailoverCategoryIfMissing -CategoryStatus $catStatus
    } else {
        Write-LogMessage "  All Failover category items already exist" -Level Success
    }

    # ── Step 6: Create or update recovery plan ────────────────────────────────
    Write-Host ""
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Step 6: Processing recovery plan: $PlanName" -Level Info
    Write-LogMessage "========================================" -Level Info

    $existingPlans = Get-RecoveryPlans
    $existingPlan  = $existingPlans | Where-Object { $_.spec.name -eq $PlanName }

    if ($existingPlan) {
        Write-LogMessage "Plan '$PlanName' already exists for cluster '$ClusterName' - nothing to do" -Level Success
        Write-LogMessage "  UUID: $($existingPlan.metadata.uuid)" -Level Info
        Write-LogMessage "  Re-run is safe (idempotent) - skipping creation" -Level Info
    }
    else {
        # First-time create: recovery network params are required
        if (-not $RecNetName -or -not $RecGateway -or $RecPrefix -eq 0 -or -not $RecStart -or -not $RecEnd) {
            Write-LogMessage "Plan '$PlanName' does not exist yet." -Level Warning
            Write-LogMessage "First-time creation requires: -RecoveryNetworkName, -RecoveryGateway, -RecoveryPrefixLength, -RecoveryStartIP, -RecoveryEndIP" -Level Error
            return
        }
        New-FailoverRecoveryPlan `
            -SourceCluster   $srcCluster `
            -RecoveryCluster $pcCluster `
            -AZUuid          $azUuid `
            -PlanName        $PlanName `
            -SrcNetName      $SrcNetName -SrcGateway $SrcGateway -SrcPrefix $SrcPrefix -SrcStart $SrcStart -SrcEnd $SrcEnd `
            -RecNetName      $RecNetName -RecGateway $RecGateway -RecPrefix $RecPrefix -RecStart $RecStart -RecEnd $RecEnd
    }

    # ── Step 7: Final validation ───────────────────────────────────────────────
    Write-Host ""
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Step 7: Final validation..." -Level Info
    Write-LogMessage "========================================" -Level Info
    $finalPlans = Get-RecoveryPlans
    $finalPlan  = $finalPlans | Where-Object { $_.spec.name -eq $PlanName }
    if ($finalPlan) {
        Wait-ForRecoveryPlanComplete -PlanUUID $finalPlan.metadata.uuid -PlanName $PlanName
    } else {
        Write-LogMessage "  ✗ '$PlanName' not found during final validation" -Level Warning
    }

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Recovery plan management completed!" -Level Success
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "  Source Cluster   : $ClusterName" -Level Info
    Write-LogMessage "  Recovery Cluster : $($pcCluster.spec.name) (PC host)" -Level Info
    Write-LogMessage "  Recovery Plan    : $PlanName" -Level Info
    Write-LogMessage "  Category Filter  : $CATEGORY_KEY = $CATEGORY_VALUE (in stage)" -Level Info
    Write-LogMessage "  Source Network   : $SrcNetName ($SrcGateway/$SrcPrefix  $SrcStart – $SrcEnd)" -Level Info
    if ($RecNetName) {
        Write-LogMessage "  Recovery Network : $RecNetName ($RecGateway/$RecPrefix  $RecStart – $RecEnd)" -Level Info
    }
    Write-Host ""
}

# ── Execute ────────────────────────────────────────────────────────────────────
try {
    Main `
        -PCAddress   $PrismCentralIP `
        -PCUsername  $Username `
        -PCPassword  $Password `
        -ClusterName $NewClusterName `
        -ClusterVip  $config.network.cluster_vip `
        -SrcNetName  $SourceNetworkName  -SrcGateway $SourceGateway  -SrcPrefix $SourcePrefixLength  -SrcStart $SourceStartIP  -SrcEnd $SourceEndIP `
        -RecNetName  $RecoveryNetworkName -RecGateway $RecoveryGateway -RecPrefix $RecoveryPrefixLength -RecStart $RecoveryStartIP -RecEnd $RecoveryEndIP
}
catch {
    Write-LogMessage "Script execution failed: $($_.Exception.Message)" -Level Error
    exit 1
}

exit 0
#endregion
