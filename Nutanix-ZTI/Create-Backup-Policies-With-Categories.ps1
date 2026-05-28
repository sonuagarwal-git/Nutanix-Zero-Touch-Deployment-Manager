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
    Optional when -PrismCentralIP, -Username, -Password and -ClusterName are supplied directly.

.PARAMETER PrismCentralIP
    Prism Central IP or FQDN. Overrides the value from ConfigFile if both are provided.

.PARAMETER Username
    Prism Central admin username.

.PARAMETER Password
    Prism Central admin password.

.PARAMETER ClusterName
    Name of the cluster to add to backup policies.
    
.EXAMPLE
    .\Manage-PC-Backup-Policies-WithCategories.ps1 -ConfigFile ".\Configs\my-cluster.json"

.EXAMPLE
    # Run without a config file — supply all values manually
    .\Create-Backup-Policies-With-Categories.ps1 -PrismCentralIP "10.0.1.20" `
        -Username "admin" -Password "MyPass!" -ClusterName "my-cluster"
    
.NOTES
    Author: Sonu Agarwal
    Date: March 24, 2026
    Version: 2.0 - Added Backup category support
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

# ── Extract backup settings from config (all values have safe defaults) ───────
# Helper: return property value if non-empty, else return default
function Get-BVal { param($obj, $prop, $default)
    if ($obj -and $null -ne $obj.$prop -and "$($obj.$prop)" -ne '') { return $obj.$prop }
    return $default
}
$backupCfg              = if ($ConfigFile -and $config -and $config.backup_policy) { $config.backup_policy } else { $null }

# If no backup section in config, skip this step gracefully
if (-not $backupCfg) {
    Write-Host ""
    Write-Host "  ► No 'backup' section found in configuration — skipping backup policy creation (Step 10)." -ForegroundColor DarkYellow
    Write-Host ""
    exit 0
}

$script:RemoteClusterName = Get-BVal $backupCfg 'remote_cluster_name' ''       # required for remote replication

$hourlyCfg  = if ($backupCfg -and $backupCfg.hourly)  { $backupCfg.hourly }  else { $null }
$dailyCfg   = if ($backupCfg -and $backupCfg.daily)   { $backupCfg.daily }   else { $null }
$weeklyCfg  = if ($backupCfg -and $backupCfg.weekly)  { $backupCfg.weekly }  else { $null }
$monthlyCfg = if ($backupCfg -and $backupCfg.monthly) { $backupCfg.monthly } else { $null }

# Build PolicyDefs only for policy types present in config (chosen in UI)
$script:PolicyDefs = [ordered]@{}
if ($hourlyCfg) {
    $script:PolicyDefs[(Get-BVal $hourlyCfg 'name' 'Hourly-Backup-Policy')] = @{
        ScheduleType    = "HOURLY"
        RPO             = [int](Get-BVal $hourlyCfg 'rpo_hours'        1)   * 3600
        LocalRetention  = [int](Get-BVal $hourlyCfg 'local_retention'  24)
        RemoteRetention = [int](Get-BVal $hourlyCfg 'remote_retention' 24)
        CategoryKey     = Get-BVal $hourlyCfg 'category_key'   'Backup'
        CategoryValue   = Get-BVal $hourlyCfg 'category_value' 'Hourly-Backup'
        AppConsistent   = [bool]($hourlyCfg.app_consistent)
    }
}
if ($dailyCfg) {
    $script:PolicyDefs[(Get-BVal $dailyCfg 'name' 'Daily-Backup-Policy')] = @{
        ScheduleType    = "DAILY"
        RPO             = [int](Get-BVal $dailyCfg   'rpo_hours'        24)  * 3600
        LocalRetention  = [int](Get-BVal $dailyCfg   'local_retention'  7)
        RemoteRetention = [int](Get-BVal $dailyCfg   'remote_retention' 7)
        CategoryKey     = Get-BVal $dailyCfg   'category_key'   'Backup'
        CategoryValue   = Get-BVal $dailyCfg   'category_value' 'Daily-Backup'
        AppConsistent   = [bool]($dailyCfg.app_consistent)
    }
}
if ($weeklyCfg) {
    $script:PolicyDefs[(Get-BVal $weeklyCfg 'name' 'Weekly-Backup-Policy')] = @{
        ScheduleType    = "WEEKLY"
        RPO             = [int](Get-BVal $weeklyCfg  'rpo_days'         7)   * 86400
        LocalRetention  = [int](Get-BVal $weeklyCfg  'local_retention'  4)
        RemoteRetention = [int](Get-BVal $weeklyCfg  'remote_retention' 4)
        CategoryKey     = Get-BVal $weeklyCfg  'category_key'   'Backup'
        CategoryValue   = Get-BVal $weeklyCfg  'category_value' 'Weekly-Backup'
        AppConsistent   = [bool]($weeklyCfg.app_consistent)
    }
}
if ($monthlyCfg) {
    $script:PolicyDefs[(Get-BVal $monthlyCfg 'name' 'Monthly-Backup-Policy')] = @{
        ScheduleType    = "MONTHLY"
        RPO             = [int](Get-BVal $monthlyCfg 'rpo_days'         30)  * 86400
        LocalRetention  = [int](Get-BVal $monthlyCfg 'local_retention'  1)
        RemoteRetention = [int](Get-BVal $monthlyCfg 'remote_retention' 6)
        CategoryKey     = Get-BVal $monthlyCfg 'category_key'   'Backup'
        CategoryValue   = Get-BVal $monthlyCfg 'category_value' 'Monthly-Backup'
        AppConsistent   = [bool]($monthlyCfg.app_consistent)
    }
}

if ($script:PolicyDefs.Count -eq 0) {
    Write-Host ""
    Write-Host "  ► No policies selected in 'backup' config — skipping backup policy creation (Step 10)." -ForegroundColor DarkYellow
    Write-Host ""
    exit 0
}

# --- Validate all required fields are present in config ---
$configErrors = [System.Collections.Generic.List[string]]::new()

if (-not $script:RemoteClusterName) {
    $configErrors.Add("backup.remote_cluster_name is required but not set")
}

$policyRawMap = @{
    hourly  = @{ cfg = $hourlyCfg;  rpoField = 'rpo_hours' }
    daily   = @{ cfg = $dailyCfg;   rpoField = 'rpo_hours' }
    weekly  = @{ cfg = $weeklyCfg;  rpoField = 'rpo_days'  }
    monthly = @{ cfg = $monthlyCfg; rpoField = 'rpo_days'  }
}
foreach ($type in $policyRawMap.Keys) {
    $raw = $policyRawMap[$type]
    if (-not $raw.cfg) { continue }  # policy not selected — skip
    $cfg  = $raw.cfg
    $rpo  = $raw.rpoField
    $pre  = "backup.$type"

    if (-not ($cfg.name))             { $configErrors.Add("$pre.name is required") }
    if (-not ($cfg.$rpo))             { $configErrors.Add("$pre.$rpo is required") }
    if (-not ($cfg.local_retention))  { $configErrors.Add("$pre.local_retention is required") }
    if (-not ($cfg.remote_retention)) { $configErrors.Add("$pre.remote_retention is required") }
    if (-not ($cfg.category_key))     { $configErrors.Add("$pre.category_key is required") }
    if (-not ($cfg.category_value))   { $configErrors.Add("$pre.category_value is required") }
}

if ($configErrors.Count -gt 0) {
    Write-Host ""
    Write-Host "  ERROR: Backup config validation failed — missing required fields:" -ForegroundColor Red
    foreach ($err in $configErrors) {
        Write-Host "    • $err" -ForegroundColor Red
    }
    Write-Host ""
    exit 1
}
# --- End validation ---

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
    
    # Find the "cluster" entry that has PRISM_CENTRAL service
    $pcEntry = $Clusters | Where-Object { $_.status.resources.config.service_list -contains "PRISM_CENTRAL" }
    
    if (-not $pcEntry) {
        Write-LogMessage "Could not find PC entry in clusters list" -Level Error
        Write-LogMessage "Could not determine which cluster hosts Prism Central" -Level Error
        return $null
    }

    $pcVMName = $pcEntry.spec.name
    Write-LogMessage "Found PC entry: $pcVMName" -Level Info

    # Helper: given a VM object, follow its cluster_reference back to the real cluster entity
    function Resolve-ClusterFromVM {
        param([object]$pcVM)
        Write-LogMessage "  Resolving cluster for VM: $($pcVM.spec.name) (UUID: $($pcVM.metadata.uuid))" -Level Info
        $detail = Invoke-PrismAPI -Method GET -Endpoint "vms/$($pcVM.metadata.uuid)"
        $hostClusterUUID = $null
        if ($detail.spec.cluster_reference)   { $hostClusterUUID = $detail.spec.cluster_reference.uuid }
        elseif ($detail.status.cluster_reference) { $hostClusterUUID = $detail.status.cluster_reference.uuid }

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

    # ── Primary strategy: subnet match on NTNX-*-PCVM-* VMs ─────────────────
    # The PC VIP (e.g. 10.0.66.25) and individual PC VM IPs (e.g. 10.0.66.26/27/28)
    # share the same /24 subnet. VM names follow: NTNX-<vm-ip-dashes>-PCVM-<suffix>
    # Match on the first 3 octets of the PC IP so we find the right PC VMs regardless
    # of whether the VIP or a VM IP is used in the name.
    try {
        $pcIp      = $PrismCentralIP                          # e.g. "10.0.66.25"
        $subnet3   = ($pcIp -split '\.')[0..2] -join '-'      # e.g. "10-0-66"

        Write-LogMessage "Searching for PCVM VMs in subnet '$subnet3.*'..." -Level Info

        $body = @{ kind = "vm"; length = 500 }
        $allPCVMs = Invoke-PrismAPI -Method POST -Endpoint "vms/list" -Body $body

        Write-LogMessage "  Found $($allPCVMs.entities.Count) total VM(s), filtering for PCVM in subnet '$subnet3'..." -Level Info

        # Filter to VMs whose name contains "PCVM" and the subnet prefix (first 3 octets)
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

    # ── Fallback: exact VM name match (works when PC registers its own name) ──
    try {
        Write-LogMessage "Falling back to exact name search for '$pcVMName'..." -Level Info
        $body = @{ kind = "vm"; filter = "vm_name==$pcVMName"; length = 10 }
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
        $body   = @{ kind = "vm"; length = 500 }
        $allVMs = Invoke-PrismAPI -Method POST -Endpoint "vms/list" -Body $body
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
        For each unique CategoryKey across all PolicyDefs, checks if the key and
        its required values exist in Prism Central.
    .OUTPUTS
        Hashtable: CategoryKey string → @{ Found; Values; MissingValues }
    #>

    # Build map: CategoryKey → [required CategoryValues]
    $keyToVals = @{}
    foreach ($policyCfg in $script:PolicyDefs.Values) {
        $ck  = $policyCfg.CategoryKey
        $val = $policyCfg.CategoryValue
        if (-not $keyToVals.ContainsKey($ck)) { $keyToVals[$ck] = @() }
        if ($keyToVals[$ck] -notcontains $val) { $keyToVals[$ck] += $val }
    }

    $result = @{}

    # Fetch all category keys once
    $allCatKeyNames = @()
    try {
        $resp = Invoke-PrismAPI -Method POST -Endpoint "categories/list" -Body @{ kind = "category"; length = 500 }
        $allCatKeyNames = @($resp.entities | ForEach-Object { $_.name })
        Write-LogMessage "Found $($allCatKeyNames.Count) category key(s) in Prism Central" -Level Info
    }
    catch {
        Write-LogMessage "Error listing category keys: $($_.Exception.Message)" -Level Error
        foreach ($ck in $keyToVals.Keys) {
            $result[$ck] = @{ Found = $false; Values = @(); MissingValues = @($keyToVals[$ck]) }
        }
        return $result
    }

    foreach ($catKey in $keyToVals.Keys) {
        $requiredVals = @($keyToVals[$catKey])
        $status = @{ Found = $false; Values = @(); MissingValues = @($requiredVals) }

        if ($allCatKeyNames -contains $catKey) {
            Write-LogMessage "  '$catKey' category key found" -Level Success
            $status.Found = $true
            try {
                $valResp   = Invoke-PrismAPI -Method POST -Endpoint "categories/$catKey/list" -Body @{ kind = "category"; length = 500 }
                $foundVals = @($valResp.entities | ForEach-Object { $_.value })
                $status.Values        = $foundVals
                $status.MissingValues = @($requiredVals | Where-Object { $foundVals -notcontains $_ })
                foreach ($v in $requiredVals) {
                    if ($foundVals -contains $v) { Write-LogMessage "    ✓ $catKey=$v" -Level Success }
                    else                         { Write-LogMessage "    ✗ $catKey=$v missing" -Level Warning }
                }
            }
            catch {
                Write-LogMessage "  Error listing values for '$catKey': $($_.Exception.Message)" -Level Error
            }
        }
        else {
            Write-LogMessage "  '$catKey' category key NOT found" -Level Warning
            Write-LogMessage "  Will create it automatically" -Level Info
        }

        $result[$catKey] = $status
    }

    return $result
}

function New-BackupCategoryIfMissing {
    <#
    .SYNOPSIS
        Creates any category keys and/or values that are absent in Prism Central.
    .PARAMETER CategoryStatusMap
        Hashtable returned by Get-BackupCategoryValues: CategoryKey → @{ Found; MissingValues }
    #>
    param(
        [hashtable]$CategoryStatusMap
    )

    foreach ($catKey in $CategoryStatusMap.Keys) {
        $status = $CategoryStatusMap[$catKey]

        # Create the key if it does not exist
        if (-not $status.Found) {
            Write-LogMessage "  Creating '$catKey' category key..." -Level Warning
            try {
                Invoke-PrismAPI -Method PUT -Endpoint "categories/$catKey" `
                    -Body @{ name = $catKey; description = "$catKey backup schedule category" } | Out-Null
                Write-LogMessage "  ✓ '$catKey' category key created" -Level Success
            }
            catch {
                Write-LogMessage "  Failed to create '$catKey': $($_.Exception.Message)" -Level Error
                throw
            }
        }

        # Create each missing value
        foreach ($val in $status.MissingValues) {
            Write-LogMessage "  Creating missing value '$catKey=$val'..." -Level Warning
            try {
                Invoke-PrismAPI -Method PUT -Endpoint "categories/$catKey/$val" `
                    -Body @{ value = $val; description = "$val backup schedule" } | Out-Null
                Write-LogMessage "  ✓ '$catKey=$val' created" -Level Success
            }
            catch {
                Write-LogMessage "  Failed to create '$catKey=$val': $($_.Exception.Message)" -Level Error
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
        [string]$CategoryValue = "",  # e.g. "Daily-Backup"
        [string]$CategoryKey   = "Backup"  # per-policy category key
    )
    
    Write-LogMessage "Creating protection policy: $PolicyName..." -Level Info
    
    if ($CategoryValue -ne "") {
        Write-LogMessage "  Applying category filter: $CategoryKey = $CategoryValue" -Level Info
        $categoryFilter = @{
            type   = "CATEGORIES_MATCH_ANY"
            params = @{ $CategoryKey = @($CategoryValue) }
        }
    } else {
        Write-LogMessage "  No category filter applied (policy covers all VMs)" -Level Warning
        $categoryFilter = @{ type = "CATEGORIES_MATCH_ANY"; params = @{} }
    }
    
    # Always use local + remote replication (2 AZ entries, bidirectional)
    $orderedAZList = @()
    $localAZ    = $AvailabilityZones | Select-Object -First 1
    $localAZUrl = ""

    if ($localAZ) {
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

    # Entry 0: Primary location (always present)
    $orderedAZList += @{
        availability_zone_url   = $localAZUrl
        availability_zone_label = "0"
        cluster_uuid_list       = @($primaryClusterUUIDs)
        target_type             = "AOS_CLUSTER"
    }

    # Build snapshot schedule
    $snapshotType = if ($ScheduleConfig.AppConsistent) { 'APPLICATION_CONSISTENT' } else { 'CRASH_CONSISTENT' }
    Write-LogMessage "  Snapshot type: $snapshotType" -Level Info
    $snapshotSchedule = @{
        recovery_point_objective_secs    = $ScheduleConfig.RPO
        local_snapshot_retention_policy  = @{ num_snapshots = $ScheduleConfig.LocalRetention }
        auto_suspend_timeout_secs        = 0
        snapshot_type                    = $snapshotType
    }

    # Build connectivity list and remote AZ entry
    $connectivityList = @()

    $snapshotSchedule.remote_snapshot_retention_policy = @{ num_snapshots = $ScheduleConfig.RemoteRetention }

    # Add remote AZ entry
    Write-LogMessage "  Adding remote cluster: $($RemoteCluster.spec.name)" -Level Info
    $orderedAZList += @{
        availability_zone_url   = $localAZUrl
        availability_zone_label = "1"
        cluster_uuid            = $RemoteCluster.metadata.uuid
        target_type             = "AOS_CLUSTER"
    }

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

    # Primary location list - index 0 is always primary
    $primaryLocationIndices = @(0)
    
    # Build the protection rule body
    $body = @{
        spec = @{
            name        = $PolicyName
            description = "Automated $ScheduleType backup policy"
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
        [string]$CategoryValue = "",
        [string]$CategoryKey   = "Backup"  # per-policy category key
    )

    Write-LogMessage "Updating policy '$($Policy.spec.name)' to include cluster: $NewClusterName..." -Level Info

    $policyDetail = Invoke-PrismAPI -Method GET -Endpoint "protection_rules/$($Policy.metadata.uuid)"

    $azList = $policyDetail.spec.resources.ordered_availability_zone_list

    if ($azList.Count -ne 2) {
        Write-LogMessage "WARNING: Expected 2 AZ entries, found $($azList.Count) — proceeding anyway" -Level Warning
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
        $existingParams    = $policyDetail.spec.resources.category_filter.params
        $existingCatValues = @()
        if ($existingParams -and $existingParams.PSObject.Properties[$CategoryKey]) {
            $existingCatValues = @($existingParams.$CategoryKey)
        }

        if ($existingCatValues -contains $CategoryValue) {
            Write-LogMessage "  ✓ Category filter already set: $CategoryKey = $CategoryValue" -Level Success
        } else {
            Write-LogMessage "  ✗ Category filter missing/incorrect (expected $CategoryKey=$CategoryValue) - will fix" -Level Warning
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
        Write-LogMessage "  Applying category filter: $CategoryKey = $CategoryValue" -Level Info
        $policyDetail.spec.resources.category_filter = @{
            type   = "CATEGORIES_MATCH_ANY"
            params = @{ $CategoryKey = @($CategoryValue) }
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
    
    # Step 2: Find the remote cluster (always required for backup policies)
    if (-not $script:RemoteClusterName) {
        Write-LogMessage "ERROR: 'backup.remote_cluster_name' is not set in config." -Level Error
        Write-LogMessage "Remote cluster name is required for backup policy creation." -Level Info
        return
    }
    Write-LogMessage "Resolving remote cluster: '$($script:RemoteClusterName)'..." -Level Info
    $pcCluster = $clusters | Where-Object {
        $_.spec.name -eq $script:RemoteClusterName -and
        $_.status.resources.config.service_list -notcontains "PRISM_CENTRAL"
    } | Select-Object -First 1
    if (-not $pcCluster) {
        Write-LogMessage "ERROR: Remote cluster '$($script:RemoteClusterName)' not found in Prism Central" -Level Error
        Write-LogMessage "Available clusters: $(($clusters | Where-Object { $_.status.resources.config.service_list -notcontains 'PRISM_CENTRAL' } | ForEach-Object { $_.spec.name }) -join ', ')" -Level Info
        return
    }
    $pcClusterName = $pcCluster.spec.name
    $pcClusterUUID = $pcCluster.metadata.uuid
    Write-LogMessage "Remote cluster resolved: $pcClusterName (UUID: $pcClusterUUID)" -Level Success
    
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

    # Step 6: Check for configured category key and values; create anything missing
    Write-Host ""
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Step 6: Checking backup categories in Prism Central..." -Level Info
    Write-LogMessage "========================================" -Level Info

    $categoryStatusMap = Get-BackupCategoryValues
    $needsCreation = @($categoryStatusMap.Values | Where-Object { -not $_.Found -or $_.MissingValues.Count -gt 0 })
    if ($needsCreation.Count -gt 0) {
        Write-LogMessage "  Some category items are missing — creating them now..." -Level Warning
        New-BackupCategoryIfMissing -CategoryStatusMap $categoryStatusMap
    } else {
        Write-LogMessage "  All required category keys and values already exist" -Level Success
    }

    Write-Host ""
    Write-LogMessage "Category assignment summary:" -Level Info
    foreach ($pName in $script:PolicyDefs.Keys) {
        $cfg = $script:PolicyDefs[$pName]
        Write-LogMessage "  $pName → $($cfg.CategoryKey) = $($cfg.CategoryValue)" -Level Success
    }

    # Step 7: Get existing protection policies
    $existingPolicies = Get-ProtectionPolicies

    # Step 8: Check and create/update policies
    Write-Host ""
    Write-LogMessage "Processing backup policies..." -Level Info
    Write-Host ""

    foreach ($policyName in $script:PolicyDefs.Keys) {
        $policyCfg      = $script:PolicyDefs[$policyName]
        $existingPolicy = $existingPolicies | Where-Object { $_.spec.name -eq $policyName }
        $catKey         = $policyCfg.CategoryKey
        $catValue       = $policyCfg.CategoryValue

        if ($existingPolicy) {
            Write-LogMessage "Policy '$policyName' already exists" -Level Info
            try {
                Update-ProtectionPolicy `
                    -Policy            $existingPolicy `
                    -NewClusterUUID    $newClusterUUID `
                    -NewClusterName    $NewClusterName `
                    -AvailabilityZones $availabilityZones `
                    -NewCluster        $newCluster `
                    -CategoryValue     $catValue `
                    -CategoryKey       $catKey
            }
            catch {
                Write-LogMessage "Failed to update policy '$policyName'" -Level Error
                throw
            }
        } else {
            Write-LogMessage "Policy '$policyName' does not exist, creating..." -Level Info
            try {
                $null = New-ProtectionPolicy `
                    -PolicyName        $policyName `
                    -ScheduleType      $policyCfg.ScheduleType `
                    -ScheduleConfig    $policyCfg `
                    -RemoteCluster     $pcCluster `
                    -PrimaryClusters   @($newCluster) `
                    -AvailabilityZones $availabilityZones `
                    -CategoryValue     $catValue `
                    -CategoryKey       $catKey
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
    Write-LogMessage "  - Mode          : $($script:BackupMode)" -Level Info
    Write-LogMessage "  - Remote cluster: $pcClusterName" -Level Info
    Write-LogMessage "  - New Cluster   : $ClusterName" -Level Info
    Write-LogMessage "  - Category key  : $($script:BackupCategoryKey)" -Level Info
    Write-LogMessage "  - Policies      : $($script:PolicyDefs.Keys.Count)" -Level Info
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
