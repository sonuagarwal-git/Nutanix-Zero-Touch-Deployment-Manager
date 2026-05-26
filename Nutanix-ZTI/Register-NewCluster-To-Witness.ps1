<#
.SYNOPSIS
    Registers a Witness VM with a two-node Nutanix cluster via Prism Element REST API.

.DESCRIPTION
    Reads cluster VIP and Witness VM details (IP, username, password, name) from the
    cluster JSON config file. Connects to Prism Element and configures the Witness VM
    for the two-node cluster to enable high availability.

.PARAMETER ConfigFile
    Path to the cluster JSON config file. Must contain network.cluster_vip and
    witness.ip / witness.username / witness.password / witness.name fields.
    Optional when -ClusterVIP, -WitnessIP, -WitnessUsername and -WitnessPassword are supplied.

.PARAMETER ClusterVIP
    Prism Element cluster VIP or IP. Overrides the value from ConfigFile if both are provided.

.PARAMETER WitnessIP
    Witness VM IP address. Overrides the value from ConfigFile if both are provided.

.PARAMETER WitnessUsername
    Witness VM admin username.

.PARAMETER WitnessPassword
    Witness VM admin password.

.PARAMETER WitnessName
    Witness VM display name (optional).

.PARAMETER ClusterUsername
    Prism Element admin username. Defaults to 'admin'.

.PARAMETER ClusterPassword
    Prism Element admin password. Defaults to 'Nutanix/4u'.

.EXAMPLE
    .\Register-NewCluster-To-Witness.ps1 -ConfigFile .\Configs\my-cluster.json

.EXAMPLE
    # Run without a config file — supply all values manually
    .\Register-NewCluster-To-Witness.ps1 -ClusterVIP "10.0.1.10" `
        -WitnessIP "10.0.1.30" -WitnessUsername "admin" -WitnessPassword "MyPass!"

.NOTES
    Author: Sonu Agarwal
    Date: Apr 08, 2026
    Version: 1.0
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$ClusterVIP,

    [Parameter(Mandatory = $false)]
    [string]$WitnessIP,

    [Parameter(Mandatory = $false)]
    [string]$WitnessUsername,

    [Parameter(Mandatory = $false)]
    [string]$WitnessPassword,

    [Parameter(Mandatory = $false)]
    [string]$WitnessName,

    [Parameter(Mandatory = $false)]
    [string]$ClusterUsername = "admin",

    [Parameter(Mandatory = $false)]
    [string]$ClusterPassword = "Nutanix/4u"
)

# Load config
if ($ConfigFile) {
    $config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    if (-not $ClusterVIP)      { $ClusterVIP      = $config.network.cluster_vip }
    if (-not $WitnessIP)       { $WitnessIP       = $config.witness.ip }
    if (-not $WitnessUsername) { $WitnessUsername = $config.witness.username }
    if (-not $WitnessPassword) { $WitnessPassword = $config.witness.password }
    if (-not $WitnessName)     { $WitnessName     = $config.witness.name }
} elseif (-not $ClusterVIP -or -not $WitnessIP -or -not $WitnessUsername -or -not $WitnessPassword) {
    Write-Host "ERROR: Provide either -ConfigFile or all of: -ClusterVIP, -WitnessIP, -WitnessUsername, -WitnessPassword." -ForegroundColor Red
    exit 1
}

$cluster_vip = $ClusterVIP
if (-not $cluster_vip) {
    Write-Host "ERROR: 'network.cluster_vip' not found in config file: $ConfigFile" -ForegroundColor Red
    exit 1
}

Write-Host "=== Register Witness VM with Two-Node Cluster ===" -ForegroundColor Cyan
Write-Host "Cluster VIP: $cluster_vip" -ForegroundColor Cyan
Write-Host "Witness IP:  $WitnessIP" -ForegroundColor Cyan
Write-Host ""

# Build credentials for Prism Element
$credString = $ClusterUsername + ":" + $ClusterPassword
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($credString))
$headers = @{
    "Authorization" = "Basic $base64Auth"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
}

try {
    # Step 1: Get current cluster configuration
    Write-Host "Step 1: Retrieving cluster configuration..." -ForegroundColor Cyan
    $clusterUri = "https://{0}:9440/api/nutanix/v2.0/cluster" -f $cluster_vip
    
    try {
        $clusterInfo = Invoke-RestMethod -Uri $clusterUri -Method GET -Headers $headers -SkipCertificateCheck
        Write-Host "  ✓ Cluster info retrieved successfully" -ForegroundColor Green
        Write-Host "  Cluster Name: $($clusterInfo.name)" -ForegroundColor Yellow
        Write-Host "  Cluster UUID: $($clusterInfo.uuid)" -ForegroundColor Yellow
        Write-Host "  Number of Nodes: $($clusterInfo.num_nodes)" -ForegroundColor Yellow
        
        if ($clusterInfo.num_nodes -ne 2) {
            Write-Host "`n  ⚠ WARNING: This cluster has $($clusterInfo.num_nodes) nodes." -ForegroundColor Yellow
            Write-Host "  Witness is only supported on 2-node clusters!" -ForegroundColor Yellow
            exit 1
        }
    } catch {
        Write-Host "  ✗ Failed to retrieve cluster info" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    
    # Step 2: Configure witness using metro_witness endpoint
    Write-Host "`nStep 2: Configuring metro witness..." -ForegroundColor Cyan
    
    # Use the correct metro_witness endpoint
    $witnessConfigUri = "https://{0}:9440/PrismGateway/services/rest/v2.0/cluster/metro_witness" -f $cluster_vip
    
    # Build the proper payload structure with custom witness name
    $witnessBody = @{
        "ip_addresses" = @($WitnessIP)
        "username" = $WitnessUsername
        "password" = $WitnessPassword
        "cluster_uuid" = $clusterInfo.uuid
        "cluster_name" = $clusterInfo.name
        "witness_name" = $WitnessName
    } | ConvertTo-Json -Depth 10
    
    Write-Host "  Sending metro witness configuration request..." -ForegroundColor Yellow
    Write-Host "  Payload:" -ForegroundColor Gray
    Write-Host "    Witness Name: $WitnessName" -ForegroundColor Gray
    Write-Host "    Witness IP: $WitnessIP" -ForegroundColor Gray
    Write-Host "    Username: $WitnessUsername" -ForegroundColor Gray
    Write-Host "    Cluster UUID: $($clusterInfo.uuid)" -ForegroundColor Gray
    Write-Host ""
    
    try {
        $witnessResult = Invoke-RestMethod -Uri $witnessConfigUri -Method POST -Headers $headers -Body $witnessBody -SkipCertificateCheck
        
        Write-Host "  ✓ Witness configuration submitted successfully!" -ForegroundColor Green
        
        if ($witnessResult.task_uuid) {
            Write-Host "  Task UUID: $($witnessResult.task_uuid)" -ForegroundColor Yellow
            
            # Monitor task progress
            Write-Host "`nStep 3: Monitoring witness configuration task..." -ForegroundColor Cyan
            $taskUri = "https://{0}:9440/api/nutanix/v2.0/tasks/{1}" -f $cluster_vip, $witnessResult.task_uuid
            
            $maxRetries = 60
            $retryCount = 0
            $taskComplete = $false
            
            while ($retryCount -lt $maxRetries) {
                Start-Sleep -Seconds 5
                
                try {
                    $taskStatus = Invoke-RestMethod -Uri $taskUri -Method GET -Headers $headers -SkipCertificateCheck
                    
                    $percentComplete = if ($taskStatus.percentage_complete) { $taskStatus.percentage_complete } else { 0 }
                    Write-Host "  [$((Get-Date).ToString('HH:mm:ss'))] Progress: $percentComplete% - Status: $($taskStatus.progress_status)" -ForegroundColor Yellow
                    
                    if ($taskStatus.progress_status -eq "Succeeded") {
                        Write-Host "`n  ✓ Witness configuration completed successfully!" -ForegroundColor Green
                        $taskComplete = $true
                        break
                    } elseif ($taskStatus.progress_status -eq "Failed") {
                        Write-Host "`n  ✗ Witness configuration task failed!" -ForegroundColor Red
                        if ($taskStatus.meta_response -and $taskStatus.meta_response.error_detail) {
                            Write-Host "  Error: $($taskStatus.meta_response.error_detail)" -ForegroundColor Red
                        }
                        exit 1
                    }
                    
                } catch {
                    Write-Host "  Warning: Could not retrieve task status" -ForegroundColor Yellow
                }
                
                $retryCount++
            }
            
            if (-not $taskComplete) {
                Write-Host "`n  ⚠ Task monitoring timed out after $($maxRetries * 5) seconds" -ForegroundColor Yellow
                Write-Host "  Please check Prism UI for task status" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  ✓ Witness configuration applied (no task returned)" -ForegroundColor Green
        }
        
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Host "  ✗ Failed to configure witness (HTTP $statusCode)" -ForegroundColor Red
        
        if ($_.ErrorDetails.Message) {
            try {
                $errorDetail = $_.ErrorDetails.Message | ConvertFrom-Json
                Write-Host "  Error: $($errorDetail.message)" -ForegroundColor Red
            } catch {
                Write-Host "  Error: $($_.ErrorDetails.Message)" -ForegroundColor Red
            }
        } else {
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        }
        
        Write-Host "`n  Troubleshooting:" -ForegroundColor Yellow
        Write-Host "  - Verify witness VM at $WitnessIP is powered on and accessible" -ForegroundColor White
        Write-Host "  - Verify witness credentials are correct" -ForegroundColor White
        Write-Host "  - Verify witness VM has all services UP (run Witness-Cluster-Start.ps1)" -ForegroundColor White
        Write-Host "  - Check cluster can reach witness VM (ping $WitnessIP from CVMs)" -ForegroundColor White
        exit 1
    }
    
    # Step 4: Verify witness configuration
    Write-Host "`nStep 4: Verifying witness configuration..." -ForegroundColor Cyan
    
    Start-Sleep -Seconds 5
    
    try {
        $witnessStatusUri = "https://{0}:9440/PrismGateway/services/rest/v2.0/cluster/metro_witness" -f $cluster_vip
        $witnessStatus = Invoke-RestMethod -Uri $witnessStatusUri -Method GET -Headers $headers -SkipCertificateCheck
        
        if ($witnessStatus) {
            Write-Host "  ✓ Witness configuration retrieved:" -ForegroundColor Green
            Write-Host "    Witness Name: $($witnessStatus.witness_name)" -ForegroundColor Yellow
            Write-Host "    IP Addresses: $($witnessStatus.ip_addresses -join ', ')" -ForegroundColor Yellow
            Write-Host "    Cluster UUID: $($witnessStatus.cluster_uuid)" -ForegroundColor Yellow
            Write-Host "    Cluster Name: $($witnessStatus.cluster_name)" -ForegroundColor Yellow
            
            if ($witnessStatus.marked_for_removal) {
                Write-Host "    ⚠ Status: Marked for removal" -ForegroundColor Yellow
            } else {
                Write-Host "    ✓ Status: Active" -ForegroundColor Green
            }
        }
        
    } catch {
        Write-Host "  Note: Could not retrieve witness status via API" -ForegroundColor Yellow
    }
    
    # Summary
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
    Write-Host "✓ Witness Configuration Complete" -ForegroundColor Green
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
    Write-Host "Witness Name: $WitnessName" -ForegroundColor Cyan
    Write-Host "Cluster VIP:  $cluster_vip" -ForegroundColor Cyan
    Write-Host "Witness IP:   $WitnessIP" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Verification Steps:" -ForegroundColor Yellow
    Write-Host "  1. Go to Prism Element: https://$cluster_vip`:9440" -ForegroundColor White
    Write-Host "  2. Check: Settings > Data Resiliency > Configure Witness" -ForegroundColor White
    Write-Host "  3. Verify witness status shows as 'Connected' or 'Active'" -ForegroundColor White
    Write-Host "  4. Check: Home > Data Resiliency Status" -ForegroundColor White
    Write-Host ""
    Write-Host "Manual Verification via SSH:" -ForegroundColor Yellow
    Write-Host "  ssh nutanix@<CVM_IP>   # Use any CVM IP from your cluster config" -ForegroundColor Cyan
    Write-Host "  ncli cluster info | grep -i external" -ForegroundColor Cyan
    Write-Host ""
    
} catch {
    Write-Host "`nUnexpected Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

exit 0
