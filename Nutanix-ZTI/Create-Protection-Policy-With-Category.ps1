<#
.SYNOPSIS
    Manage Prism Central Cross-Site Replication (Failover) Protection Policy for Nutanix Clusters
    
.DESCRIPTION
    This script connects to Prism Central, identifies the cluster hosting the PC VM,
    and creates or updates a single Failover protection policy for cross-site replication.

    - Target (remote) location: always the cluster where Prism Central VM is running
    - Source (primary) location: the cluster name provided as input (-NewClusterName)
    - If the policy already exists: adds the new cluster to the existing policy
    - Category: checks for "Failover" key with value "Failover"; creates them if missing
    - Category filter: applied to the policy on create; corrected on update if missing

.PARAMETER ConfigFile
    Path to the cluster JSON config file.
    Optional when -PrismCentralIP, -Username, -Password and -ClusterName are supplied directly.

.PARAMETER PrismCentralIP
    Prism Central IP or FQDN. Overrides the value from ConfigFile if both are provided.

.PARAMETER Username
    Prism Central admin username.

.PARAMETER Password
    Prism Central admin password.

.PARAMETER ClusterName
    Name of the cluster to add to the protection policy.

.EXAMPLE
    .\Manage-Protection-Policy-With-Category.ps1 -ConfigFile ".\Configs\my-cluster.json"

.EXAMPLE
    # Run without a config file — supply all values manually
    .\Create-Protection-Policy-With-Category.ps1 -PrismCentralIP "10.0.1.20" `
        -Username "admin" -Password "MyPass!" -ClusterName "my-cluster"

.NOTES
    Author: Sonu Agarwal
    Date: March 26, 2026
    Version: 1.0 - Cross-site failover protection policy with category support
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
    [string]$ClusterName
)

# Load config
if ($ConfigFile) {
    $config         = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    if (-not $PrismCentralIP) { $PrismCentralIP = $config.prism_central.ip }
    if (-not $Username)       { $Username       = $config.prism_central.username }
    if (-not $Password)       { $Password       = $config.prism_central.password }
    if (-not $ClusterName)    { $ClusterName    = $config.clusterName }
} elseif (-not $PrismCentralIP -or -not $Username -or -not $Password -or -not $ClusterName) {
    Write-Host "ERROR: Provide either -ConfigFile or all of: -PrismCentralIP, -Username, -Password, -ClusterName." -ForegroundColor Red
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

# ── Load protection_policy config section ─────────────────────────────────────
$ppCfg = if ($config -and $config.protection_policy) { $config.protection_policy } else { $null }

if (-not $ppCfg) {
    Write-Host ""
    Write-Host "  ► No 'protection_policy' section found in configuration — skipping (Step 11)." -ForegroundColor DarkYellow
    Write-Host ""
    exit 0
}

# Validate all required fields up-front
$ppErrors = [System.Collections.Generic.List[string]]::new()
if (-not $ppCfg.remote_cluster_name) { $ppErrors.Add("protection_policy.remote_cluster_name is required") }
if (-not $ppCfg.name)                { $ppErrors.Add("protection_policy.name is required") }
if (-not $ppCfg.rpo_hours)           { $ppErrors.Add("protection_policy.rpo_hours is required") }
if (-not $ppCfg.local_retention)     { $ppErrors.Add("protection_policy.local_retention is required") }
if (-not $ppCfg.remote_retention)    { $ppErrors.Add("protection_policy.remote_retention is required") }
if (-not $ppCfg.category_key)        { $ppErrors.Add("protection_policy.category_key is required") }
if (-not $ppCfg.category_value)      { $ppErrors.Add("protection_policy.category_value is required") }

if ($ppErrors.Count -gt 0) {
    Write-Host ""
    Write-Host "  ERROR: Protection policy config validation failed — missing required fields:" -ForegroundColor Red
    foreach ($err in $ppErrors) { Write-Host "    • $err" -ForegroundColor Red }
    Write-Host ""
    exit 1
}

# ── Policy settings (from config with defaults) ────────────────────────────────
$POLICY_NAME             = $ppCfg.name
$POLICY_REMOTE_CLUSTER   = $ppCfg.remote_cluster_name
$CATEGORY_KEY            = $ppCfg.category_key
$CATEGORY_VALUE          = $ppCfg.category_value
$POLICY_RPO              = [int]$ppCfg.rpo_hours * 3600
$POLICY_LOCAL_RETENTION  = [int]$ppCfg.local_retention
$POLICY_REMOTE_RETENTION = [int]$ppCfg.remote_retention
$POLICY_APP_CONSISTENT   = [bool]($ppCfg.app_consistent)

# ── Certificate bypass ─────────────────────────────────────────────────────────
if ($PSVersionTable.PSVersion.Major -ge 6) {
    # PowerShell 6+ handles this per-request via -SkipCertificateCheck
} else {
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
        if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress) }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }
        return Invoke-RestMethod @params
    }
    catch {
        Write-LogMessage "API Error: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Get-AllClusters {
    Write-LogMessage "Retrieving all clusters from Prism Central..." -Level Info
    $body     = @{ kind = "cluster"; length = 500 }
    $response = Invoke-PrismAPI -Method POST -Endpoint "clusters/list" -Body $body

    $realClusters = $response.entities | Where-Object {
        $_.spec.name -notmatch "^Unnamed$" -and
        $_.status.resources.config.service_list -notcontains "PRISM_CENTRAL"
    }
    Write-LogMessage "Found $($realClusters.Count) Nutanix cluster(s)" -Level Success
    foreach ($c in $realClusters) {
        Write-LogMessage "  - $($c.spec.name)" -Level Info
    }
    return $response.entities
}

function Get-AvailabilityZones {
    Write-LogMessage "Retrieving Availability Zones..." -Level Info
    $response = Invoke-PrismAPI -Method POST -Endpoint "availability_zones/list" -Body @{ kind = "availability_zone"; length = 500 }
    Write-LogMessage "Found $($response.entities.Count) Availability Zone(s)" -Level Success
    foreach ($az in $response.entities) {
        Write-LogMessage "  - AZ: $($az.spec.resources.name) (URL: $($az.spec.resources.management_url))" -Level Info
    }
    return $response.entities
}

function Get-ProtectionPolicies {
    Write-LogMessage "Retrieving existing protection policies..." -Level Info
    $response = Invoke-PrismAPI -Method POST -Endpoint "protection_rules/list" -Body @{ kind = "protection_rule"; length = 500 }
    Write-LogMessage "Found $($response.entities.Count) protection policy/policies" -Level Info
    return $response.entities
}

#region Category Functions

function Get-FailoverCategoryStatus {
    <#
    .SYNOPSIS
        Checks whether the "Failover" category key and "Failover" value exist.
    .OUTPUTS
        Hashtable: Found, HasFailover
    #>
    Write-LogMessage "Checking for '$CATEGORY_KEY' category in Prism Central..." -Level Info

    $result = @{ Found = $false; HasFailover = $false }

    # -- Check key exists --
    try {
        $keysResp = Invoke-PrismAPI -Method POST -Endpoint "categories/list" -Body @{ kind = "category"; length = 500 }
        Write-LogMessage "Found $($keysResp.entities.Count) category key(s)" -Level Info

        $key = $keysResp.entities | Where-Object { $_.name -eq $CATEGORY_KEY }
        if ($key) {
            Write-LogMessage "  ✓ '$CATEGORY_KEY' category key found" -Level Success
            $result.Found = $true
        } else {
            Write-LogMessage "  '$CATEGORY_KEY' category key NOT found" -Level Warning
            return $result
        }
    }
    catch {
        Write-LogMessage "Error checking category keys: $($_.Exception.Message)" -Level Error
        throw
    }

    # -- Check value exists --
    try {
        $valsResp = Invoke-PrismAPI -Method POST -Endpoint "categories/$CATEGORY_KEY/list" -Body @{ kind = "category"; length = 500 }
        $values   = @($valsResp.entities | ForEach-Object { $_.value })
        Write-LogMessage "  '$CATEGORY_KEY' values found: $($values -join ', ')" -Level Info

        if ($values -contains $CATEGORY_VALUE) {
            Write-LogMessage "  ✓ Value '$CATEGORY_VALUE' found" -Level Success
            $result.HasFailover = $true
        } else {
            Write-LogMessage "  ✗ Value '$CATEGORY_VALUE' NOT found" -Level Warning
        }
    }
    catch {
        Write-LogMessage "Error checking category values: $($_.Exception.Message)" -Level Error
        throw
    }

    return $result
}

function New-FailoverCategoryIfMissing {
    <#
    .SYNOPSIS
        Creates the "Failover" category key and/or "Failover" value if either is missing.
    #>
    param([hashtable]$CategoryStatus)

    # Create key if missing
    if (-not $CategoryStatus.Found) {
        Write-LogMessage "  Creating '$CATEGORY_KEY' category key..." -Level Warning
        try {
            Invoke-PrismAPI -Method PUT -Endpoint "categories/$CATEGORY_KEY" -Body @{
                name        = $CATEGORY_KEY
                description = "Failover category"
            } | Out-Null
            Write-LogMessage "  ✓ '$CATEGORY_KEY' category key created" -Level Success
        }
        catch {
            Write-LogMessage "  Failed to create '$CATEGORY_KEY' key: $($_.Exception.Message)" -Level Error
            throw
        }
    }

    # Create value if missing
    if (-not $CategoryStatus.HasFailover) {
        Write-LogMessage "  Creating value '$CATEGORY_VALUE' under '$CATEGORY_KEY'..." -Level Warning
        try {
            Invoke-PrismAPI -Method PUT -Endpoint "categories/$CATEGORY_KEY/$CATEGORY_VALUE" -Body @{
                value       = $CATEGORY_VALUE
                description = "Failover replication"
            } | Out-Null
            Write-LogMessage "  ✓ Value '$CATEGORY_VALUE' created" -Level Success
        }
        catch {
            Write-LogMessage "  Failed to create value '$CATEGORY_VALUE': $($_.Exception.Message)" -Level Error
            throw
        }
    }
}

#endregion

function New-FailoverProtectionPolicy {
    param(
        [object]$RemoteCluster,
        [array]$PrimaryClusters,
        [array]$AvailabilityZones
    )

    Write-LogMessage "Creating protection policy: $POLICY_NAME..." -Level Info
    Write-LogMessage "  Applying category filter: $CATEGORY_KEY = $CATEGORY_VALUE" -Level Info

    $localAZUrl = ($AvailabilityZones | Select-Object -First 1).spec.resources.management_url
    if (-not $localAZUrl) { Write-LogMessage "WARNING: No AZ URL found" -Level Warning }

    # Build primary cluster UUID list
    $primaryUUIDs = @()
    foreach ($c in $PrimaryClusters) {
        Write-LogMessage "  Source cluster: $($c.spec.name)" -Level Info
        $primaryUUIDs += $c.metadata.uuid
    }

    # Ordered AZ list: [0] = source (primary), [1] = target (PC cluster)
    $orderedAZList = @(
        @{
            availability_zone_url   = $localAZUrl
            availability_zone_label = "0"
            cluster_uuid_list       = @($primaryUUIDs)
            target_type             = "AOS_CLUSTER"
        },
        @{
            availability_zone_url   = $localAZUrl
            availability_zone_label = "1"
            cluster_uuid            = $RemoteCluster.metadata.uuid
            target_type             = "AOS_CLUSTER"
        }
    )

    Write-LogMessage "  Target (remote) cluster: $($RemoteCluster.spec.name)" -Level Info

    $snapshotType = if ($POLICY_APP_CONSISTENT) { 'APPLICATION_CONSISTENT' } else { 'CRASH_CONSISTENT' }
    Write-LogMessage "  Snapshot type: $snapshotType" -Level Info
    $snapshotSchedule = @{
        recovery_point_objective_secs    = $POLICY_RPO
        local_snapshot_retention_policy  = @{ num_snapshots = $POLICY_LOCAL_RETENTION  }
        remote_snapshot_retention_policy = @{ num_snapshots = $POLICY_REMOTE_RETENTION }
        auto_suspend_timeout_secs        = 0
        snapshot_type                    = $snapshotType
    }

    $connectivityList = @(
        @{
            source_availability_zone_index      = 0
            destination_availability_zone_index = 1
            source_availability_zone_label      = "0"
            destination_availability_zone_label = "1"
            snapshot_schedule_list              = @($snapshotSchedule)
        },
        @{
            source_availability_zone_index      = 1
            destination_availability_zone_index = 0
            source_availability_zone_label      = "1"
            destination_availability_zone_label = "0"
            snapshot_schedule_list              = @($snapshotSchedule)
        }
    )

    $body = @{
        spec     = @{
            name        = $POLICY_NAME
            description = "Cross-site replication Failover policy"
            resources   = @{
                start_time                          = ""
                ordered_availability_zone_list      = $orderedAZList
                availability_zone_connectivity_list = $connectivityList
                primary_location_list               = @(0)
                category_filter                     = @{
                    type   = "CATEGORIES_MATCH_ANY"
                    params = @{ $CATEGORY_KEY = @($CATEGORY_VALUE) }
                }
            }
        }
        metadata = @{ kind = "protection_rule" }
    }

    # Single POST — same pattern as the working backup policy script.
    # (Retry loops risk creating duplicate rules on transient failures.)
    $response = Invoke-PrismAPI -Method POST -Endpoint "protection_rules" -Body $body

    # Log the immediate POST response state/messages so we can see PC rejection early.
    if ($response.status) {
        Write-LogMessage "Initial response state: $($response.status.state)" -Level Info
        if ($response.status.message_list) {
            Write-LogMessage "Initial state messages:" -Level Warning
            foreach ($msg in $response.status.message_list) {
                Write-LogMessage "  - $($msg.message)" -Level Warning
            }
        }
    }

    try {
        $policyUUID = $response.metadata.uuid
        Write-LogMessage "Policy UUID: $policyUUID" -Level Info

        # Poll until COMPLETE or timeout
        # 404 on early polls is normal — PC indexes rules async after POST; treat as PENDING.
        $maxWait     = 120; $interval = 10; $elapsed = 0; $state = ""; $consecutive404 = 0
        Write-LogMessage "Waiting for policy to be processed (max ${maxWait}s)..." -Level Info

        do {
            Start-Sleep -Seconds $interval
            $elapsed += $interval
            try {
                $check = Invoke-PrismAPI -Method GET -Endpoint "protection_rules/$policyUUID"
                $consecutive404 = 0
                $state = $check.status.state
                Write-LogMessage "  [${elapsed}s] Policy state: $state" -Level Info
            }
            catch {
                if ($_ -match "404") {
                    $consecutive404++
                    Write-LogMessage "  [${elapsed}s] Policy not yet indexed (404) — retrying... ($consecutive404)" -Level Info
                    if ($consecutive404 -ge 6) { throw "Policy rejected by Prism Central (still 404 after 60s)" }
                    # continue polling
                }
                else { throw }
            }
        } while (($state -eq "PENDING" -or $state -eq "RUNNING" -or $state -eq "") -and $elapsed -lt $maxWait)

        if ($state -eq "COMPLETE") {
            Write-LogMessage "Policy '$POLICY_NAME' created successfully and is ACTIVE" -Level Success
            return $response
        }
        elseif ($elapsed -ge $maxWait -and ($state -eq "PENDING" -or $state -eq "RUNNING")) {
            Write-LogMessage "Policy still in '$state' after ${maxWait}s - submitted OK, Prism is still applying" -Level Warning
            return $response
        }
        else {
            Write-LogMessage "Policy ended in unexpected state: $state" -Level Error
            if ($check.status.message_list) {
                foreach ($msg in $check.status.message_list) { Write-LogMessage "  - $($msg.message)" -Level Error }
            }
            throw "Policy creation failed with state: $state"
        }
    }
    catch {
        $detail = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { "" }
        Write-LogMessage "FAILED to create policy: $POLICY_NAME" -Level Error
        Write-LogMessage "Error: $($_.Exception.Message)" -Level Error
        if ($detail) { Write-LogMessage "API response: $detail" -Level Error }
        Write-LogMessage "Policy body sent:" -Level Info
        Write-LogMessage ($body | ConvertTo-Json -Depth 10) -Level Info
        throw
    }
}

function Update-FailoverProtectionPolicy {
    param(
        [object]$Policy,
        [string]$NewClusterUUID,
        [string]$NewClusterName,
        [array]$AvailabilityZones
    )

    Write-LogMessage "Updating '$($Policy.spec.name)' to include cluster: $NewClusterName..." -Level Info

    $policyDetail = Invoke-PrismAPI -Method GET -Endpoint "protection_rules/$($Policy.metadata.uuid)"
    $azList       = $policyDetail.spec.resources.ordered_availability_zone_list

    if ($azList.Count -ne 2) {
        Write-LogMessage "ERROR: Expected 2 AZ entries, found $($azList.Count)" -Level Error
        throw "Invalid policy structure"
    }

    $primaryAZ = $azList[0]
    $remoteAZ  = $azList[1]

    # Build set of live cluster UUIDs from PC so stale entries are dropped on update
    $liveClusterUUIDs = @(Get-AllClusters | ForEach-Object { $_.metadata.uuid })

    # Show current clusters
    Write-LogMessage "Current primary clusters in policy:" -Level Info
    if ($primaryAZ.cluster_uuid_list) {
        foreach ($uuid in $primaryAZ.cluster_uuid_list) {
            $isLive = if ($liveClusterUUIDs -contains $uuid) { 'live' } else { 'STALE - will be removed' }
            Write-LogMessage "  - $uuid ($isLive)" -Level Info
        }
    } else {
        Write-LogMessage "  (none listed)" -Level Warning
    }

    # Check cluster presence
    $clusterAlreadyPresent = ($primaryAZ.cluster_uuid_list -contains $NewClusterUUID)

    # Check category filter (only verify, never re-create — categories managed separately)
    $categoryNeedsUpdate = $false
    $existingParams      = $policyDetail.spec.resources.category_filter.params
    $existingValues      = @()
    if ($existingParams -and $existingParams.PSObject.Properties[$CATEGORY_KEY]) {
        $existingValues = @($existingParams.$CATEGORY_KEY)
    }

    if ($existingValues -contains $CATEGORY_VALUE) {
        Write-LogMessage "  ✓ Category filter already set: $CATEGORY_KEY = $CATEGORY_VALUE" -Level Success
    } else {
        Write-LogMessage "  ✗ Category filter missing/wrong (expected $CATEGORY_KEY=$CATEGORY_VALUE, found: '$($existingValues -join ', ')') - will fix" -Level Warning
        $categoryNeedsUpdate = $true
    }

    # Nothing to do?
    if ($clusterAlreadyPresent -and -not $categoryNeedsUpdate) {
        Write-LogMessage "  Policy is already up to date - no changes needed" -Level Info
        return $policyDetail
    }

    $localAZUrl = ($AvailabilityZones | Select-Object -First 1).spec.resources.management_url

    # Build updated cluster list: keep only live UUIDs, then add the new cluster.
    $updatedUUIDs = @()
    if ($primaryAZ.cluster_uuid_list) {
        $preserved = @($primaryAZ.cluster_uuid_list | Where-Object { $liveClusterUUIDs -contains $_ })
        $dropped   = @($primaryAZ.cluster_uuid_list | Where-Object { $liveClusterUUIDs -notcontains $_ })
        if ($dropped.Count -gt 0) {
            Write-LogMessage "  Removing $($dropped.Count) stale UUID(s) no longer in PC: $($dropped -join ', ')" -Level Warning
        }
        $updatedUUIDs += $preserved
        Write-LogMessage "  Preserving $($preserved.Count) live existing cluster(s)" -Level Info
    }
    if (-not $clusterAlreadyPresent) {
        $updatedUUIDs += $NewClusterUUID
        Write-LogMessage "  Total clusters after update: $($updatedUUIDs.Count)" -Level Info
    } else {
        Write-LogMessage "  Cluster already present - only fixing category filter" -Level Info
    }

    $newAZList = @(
        @{
            availability_zone_url   = $localAZUrl
            availability_zone_label = "0"
            cluster_uuid_list       = @($updatedUUIDs)
            target_type             = "AOS_CLUSTER"
        },
        @{
            availability_zone_url   = $localAZUrl
            availability_zone_label = "1"
            cluster_uuid            = if ($remoteAZ.cluster_uuid) { $remoteAZ.cluster_uuid } else { $remoteAZ.cluster_uuid_list[0] }
            target_type             = "AOS_CLUSTER"
        }
    )

    $existingConn  = $policyDetail.spec.resources.availability_zone_connectivity_list
    $sampleSchedule = $existingConn[0].snapshot_schedule_list[0]

    $newConnectivity = @(
        @{
            source_availability_zone_index      = 0
            destination_availability_zone_index = 1
            source_availability_zone_label      = "0"
            destination_availability_zone_label = "1"
            snapshot_schedule_list              = @($sampleSchedule)
        },
        @{
            source_availability_zone_index      = 1
            destination_availability_zone_index = 0
            source_availability_zone_label      = "1"
            destination_availability_zone_label = "0"
            snapshot_schedule_list              = @($sampleSchedule)
        }
    )

    $policyDetail.spec.resources.ordered_availability_zone_list      = $newAZList
    $policyDetail.spec.resources.primary_location_list               = @(0)
    $policyDetail.spec.resources.availability_zone_connectivity_list = $newConnectivity

    if ($categoryNeedsUpdate) {
        Write-LogMessage "  Applying category filter: $CATEGORY_KEY = $CATEGORY_VALUE" -Level Info
        $policyDetail.spec.resources.category_filter = @{
            type   = "CATEGORIES_MATCH_ANY"
            params = @{ $CATEGORY_KEY = @($CATEGORY_VALUE) }
        }
    }

    $updateBody = @{
        spec     = $policyDetail.spec
        metadata = @{
            kind         = $policyDetail.metadata.kind
            uuid         = $policyDetail.metadata.uuid
            spec_version = $policyDetail.metadata.spec_version
        }
    }

    try {
        $response = Invoke-PrismAPI -Method PUT -Endpoint "protection_rules/$($Policy.metadata.uuid)" -Body $updateBody
        Write-LogMessage "Successfully updated policy: $($Policy.spec.name)" -Level Success

        # Validate state after update
        Start-Sleep -Seconds 5
        $check = Invoke-PrismAPI -Method GET -Endpoint "protection_rules/$($Policy.metadata.uuid)"
        Write-LogMessage "Policy state after update: $($check.status.state)" -Level Info
        return $response
    }
    catch {
        $detail = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { "" }
        Write-LogMessage "Failed to update policy: $($_.Exception.Message)" -Level Error
        if ($detail) { Write-LogMessage "API response: $detail" -Level Error }
        throw
    }
}

function Wait-ForPolicyComplete {
    param([string]$PolicyUUID, [string]$PolicyName)
    # maxWait increased to 300s — after a cluster-list change Prism can take
    # several minutes to re-broadcast the rule to all member clusters.
    $maxWait         = 300; $interval = 10; $elapsed = 0; $state = ""
    $consecutive404  = 0;   $maxConsecutive404 = 12   # tolerate up to 120s of 404s
    $check           = $null
    Write-LogMessage "Waiting for '$PolicyName' to reach COMPLETE state (max ${maxWait}s)..." -Level Info

    do {
        try {
            $check  = Invoke-PrismAPI -Method GET -Endpoint "protection_rules/$PolicyUUID"
            $state  = $check.status.state
            $consecutive404 = 0
        } catch {
            if ($_ -match '404') {
                $consecutive404++
                Write-LogMessage "  [${elapsed}s] $PolicyName : UUID not found (404) — Prism may be re-keying rule, retrying... ($consecutive404/$maxConsecutive404)" -Level Info
                if ($consecutive404 -ge $maxConsecutive404) {
                    Write-LogMessage "  ⚠ $PolicyName : Still 404 after $($consecutive404 * $interval)s — treating as applied (Prism re-keyed the rule)" -Level Warning
                    return
                }
                $state = "PENDING"
            } else {
                throw
            }
        }
        if ($state -eq "COMPLETE") { break }
        Write-LogMessage "  [${elapsed}s] $PolicyName : $state - waiting..." -Level Info
        Start-Sleep -Seconds $interval
        $elapsed += $interval
    } while ($elapsed -lt $maxWait)

    if ($state -eq "COMPLETE") {
        Write-LogMessage "  ✓ $PolicyName : Active" -Level Success
    } elseif ($elapsed -ge $maxWait) {
        Write-LogMessage "  ⚠ $PolicyName : Still '$state' after ${maxWait}s - Prism is still applying (not an error)" -Level Warning
    } else {
        Write-LogMessage "  ✗ $PolicyName : $state" -Level Warning
        if ($check -and $check.status.message_list) {
            foreach ($msg in $check.status.message_list) { Write-LogMessage "    - $($msg.message)" -Level Warning }
        }
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

    $script:PrismCentralBaseURL = "https://${PCAddress}:9440/api/nutanix/v3"
    $script:Headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${PCUsername}:${PCPassword}"))
    }

    Write-LogMessage "Connecting to Prism Central: $PCAddress" -Level Info
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Failover Protection Policy Management" -Level Info
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
        if ($code -eq 401) {
            Write-LogMessage "  Check: correct password, correct PC IP (not Prism Element VIP)" -Level Error
        }
        throw "Authentication failed"
    }
    Write-Host ""

    # ── Step 1: Get all clusters ───────────────────────────────────────────────
    $clusters = Get-AllClusters
    if ($clusters.Count -eq 0) { Write-LogMessage "No clusters found" -Level Error; return }

    # ── Step 2: Resolve remote (target) cluster by name from config ───────────
    Write-LogMessage "Resolving remote cluster: '$POLICY_REMOTE_CLUSTER'..." -Level Info
    $pcCluster = $clusters | Where-Object {
        $_.spec.name -eq $POLICY_REMOTE_CLUSTER -and
        $_.status.resources.config.service_list -notcontains "PRISM_CENTRAL"
    } | Select-Object -First 1
    if (-not $pcCluster) {
        Write-LogMessage "ERROR: Remote cluster '$POLICY_REMOTE_CLUSTER' not found in Prism Central" -Level Error
        Write-LogMessage "Available clusters: $(($clusters | Where-Object { $_.status.resources.config.service_list -notcontains 'PRISM_CENTRAL' } | ForEach-Object { $_.spec.name }) -join ', ')" -Level Info
        return
    }
    Write-LogMessage "Remote cluster resolved: $($pcCluster.spec.name) (UUID: $($pcCluster.metadata.uuid))" -Level Success

    # ── Step 3: Find source cluster (input), deduplicate stale registrations ──
    $matchingClusters = @($clusters | Where-Object {
        $_.spec.name -eq $ClusterName -and
        $_.status.resources.config.service_list -notcontains "PRISM_CENTRAL"
    })

    if ($matchingClusters.Count -eq 0) {
        Write-LogMessage "Cluster '$ClusterName' not found in Prism Central" -Level Error
        Write-LogMessage "Available: $(($clusters | Where-Object { $_.status.resources.config.service_list -notcontains 'PRISM_CENTRAL' }).spec.name -join ', ')" -Level Info
        return
    }

    $newCluster = if ($matchingClusters.Count -gt 1 -and $ClusterVip) {
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

    Write-LogMessage "Source cluster: $ClusterName (UUID: $($newCluster.metadata.uuid))" -Level Success
    Write-LogMessage "Target cluster: $($pcCluster.spec.name) (UUID: $($pcCluster.metadata.uuid))" -Level Info

    # ── Step 4: Get Availability Zones ────────────────────────────────────────
    Write-Host ""
    $availabilityZones = Get-AvailabilityZones
    if ($availabilityZones.Count -eq 0) {
        Write-LogMessage "No Availability Zones found - clusters must be registered as AZs" -Level Error
        return
    }

    # ── Step 5: Ensure Failover category exists ───────────────────────────────
    Write-Host ""
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Step 5: Checking Failover category..." -Level Info
    Write-LogMessage "========================================" -Level Info

    $catStatus = Get-FailoverCategoryStatus

    $needsCreate = (-not $catStatus.Found) -or (-not $catStatus.HasFailover)
    if ($needsCreate) {
        Write-LogMessage "  Missing category items - creating now..." -Level Warning
        New-FailoverCategoryIfMissing -CategoryStatus $catStatus
    } else {
        Write-LogMessage "  All required Failover category items already exist" -Level Success
    }
    Write-Host ""
    Write-LogMessage "  $POLICY_NAME → Category: $CATEGORY_KEY = $CATEGORY_VALUE" -Level Success

    # ── Step 6: Get existing policies and create/update ───────────────────────
    Write-Host ""
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Step 6: Processing Failover protection policy..." -Level Info
    Write-LogMessage "========================================" -Level Info

    $existingPolicies = Get-ProtectionPolicies
    $existingPolicy   = $existingPolicies | Where-Object { $_.spec.name -eq $POLICY_NAME }

    if ($existingPolicy) {
        Write-LogMessage "Policy '$POLICY_NAME' already exists - checking for updates..." -Level Info
        try {
            Update-FailoverProtectionPolicy `
                -Policy          $existingPolicy `
                -NewClusterUUID  $newCluster.metadata.uuid `
                -NewClusterName  $ClusterName `
                -AvailabilityZones $availabilityZones
        }
        catch {
            Write-LogMessage "Failed to update policy '$POLICY_NAME'" -Level Error
            throw
        }
    }
    else {
        Write-LogMessage "Policy '$POLICY_NAME' does not exist - creating..." -Level Info
        try {
            New-FailoverProtectionPolicy `
                -RemoteCluster     $pcCluster `
                -PrimaryClusters   @($newCluster) `
                -AvailabilityZones $availabilityZones
        }
        catch {
            Write-LogMessage "Failed to create policy '$POLICY_NAME'" -Level Error
            throw
        }
    }

    # ── Step 7: Final validation with polling ─────────────────────────────────
    Write-Host ""
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Step 7: Validating final policy state..." -Level Info
    Write-LogMessage "========================================" -Level Info

    $finalPolicies = Get-ProtectionPolicies
    $finalPolicy   = $finalPolicies | Where-Object { $_.spec.name -eq $POLICY_NAME }

    if ($finalPolicy) {
        Wait-ForPolicyComplete -PolicyUUID $finalPolicy.metadata.uuid -PolicyName $POLICY_NAME
    } else {
        Write-LogMessage "  ✗ '$POLICY_NAME' not found during final validation" -Level Warning
    }

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Failover policy management completed!" -Level Success
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "  Source Cluster : $ClusterName" -Level Info
    Write-LogMessage "  Target Cluster : $($pcCluster.spec.name)" -Level Info
    Write-LogMessage "  Policy         : $POLICY_NAME" -Level Info
    Write-LogMessage "  Category       : $CATEGORY_KEY = $CATEGORY_VALUE" -Level Info
    Write-LogMessage "  RPO            : $($POLICY_RPO / 3600) hour(s)" -Level Info
    Write-LogMessage "  Retention      : $POLICY_LOCAL_RETENTION local / $POLICY_REMOTE_RETENTION remote snapshots" -Level Info
    Write-LogMessage "  App Consistent : $(if ($POLICY_APP_CONSISTENT) { 'Yes' } else { 'No' })" -Level Info
    Write-Host ""
}

# ── Execute ────────────────────────────────────────────────────────────────────
try {
    Main -PCAddress $PrismCentralIP -PCUsername $Username -PCPassword $Password -ClusterName $NewClusterName -ClusterVip $config.network.cluster_vip
}
catch {
    Write-LogMessage "Script execution failed: $($_.Exception.Message)" -Level Error
    exit 1
}

exit 0
#endregion
