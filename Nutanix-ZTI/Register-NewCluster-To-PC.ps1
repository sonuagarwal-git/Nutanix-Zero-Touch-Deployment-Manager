param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$CVMIP  # Optional - will auto-detect if not provided
)

# Load config
$config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
$cluster_vip = $config.network.cluster_vip
if (-not $cluster_vip) {
    Write-Host "ERROR: 'network.cluster_vip' not found in config file: $ConfigFile" -ForegroundColor Red
    exit 1
}
$PrismCentralIP       = $config.prism_central.ip
$PrismCentralUsername = $config.prism_central.username
$PrismCentralPassword = $config.prism_central.password

# Hardcoded credentials
$ClusterUsername       = "admin"
$ClusterPassword       = "Nutanix/4u"
$ClusterCVMSSHUsername = "nutanix"
$ClusterCVMSSHPassword = "nutanix/4u"

Write-Host "=== Register Nutanix Cluster to Prism Central via NCLI ===" -ForegroundColor Cyan

# Check if Posh-SSH module is available
if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Write-Host "`nPosh-SSH module not found. Installing..." -ForegroundColor Yellow
    try {
        Install-Module -Name Posh-SSH -Force -Scope CurrentUser
        Write-Host "Posh-SSH module installed successfully." -ForegroundColor Green
    } catch {
        Write-Host "Failed to install Posh-SSH module." -ForegroundColor Red
        exit 1
    }
}

Import-Module Posh-SSH

# Helper function for compatible SSH connections
function New-CompatibleSSHSession {
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential
    )
    
    try {
        # First attempt: Standard connection
        Write-Host "  Attempting standard SSH connection..." -ForegroundColor Gray
        $session = New-SSHSession -ComputerName $ComputerName -Credential $Credential -AcceptKey -Port 22 -ErrorAction Stop
        Write-Host "  Γ£ô Standard connection successful" -ForegroundColor Green
        return $session
    }
    catch {
        Write-Host "  Standard connection failed, trying compatibility mode..." -ForegroundColor Yellow
        
        try {
            # Second attempt: With connection info for older SSH servers
            $username = $Credential.UserName
            $password = $Credential.GetNetworkCredential().Password
            
            # Create connection info with compatibility settings
            $connectionInfo = New-Object Renci.SshNet.ConnectionInfo(
                $ComputerName,
                22,
                $username,
                (New-Object Renci.SshNet.PasswordAuthenticationMethod($username, $password))
            )
            
            # Set timeout
            $connectionInfo.Timeout = [TimeSpan]::FromSeconds(30)
            
            # Create SSH client
            $sshClient = New-Object Renci.SshNet.SshClient($connectionInfo)
            $sshClient.Connect()
            
            if ($sshClient.IsConnected) {
                # Create a new SSH session from the connected client
                $session = New-SSHSession -ComputerName $ComputerName -Credential $Credential -AcceptKey -Force -ErrorAction Stop
                Write-Host "  Γ£ô Compatibility mode connection successful" -ForegroundColor Green
                return $session
            }
        }
        catch {
            throw $_
        }
    }
}

# Build credentials for REST API
$clusterCredString = $ClusterUsername + ":" + $ClusterPassword
$clusterBase64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($clusterCredString))
$clusterHeaders = @{
    "Authorization" = "Basic $clusterBase64Auth"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
}

# Step 1: Get cluster details and CVM IP
Write-Host "`nStep 1: Retrieving cluster details from Prism Element ($cluster_vip)..." -ForegroundColor Yellow

$clusterInfoUri = "https://{0}:9440/PrismGateway/services/rest/v2.0/cluster" -f $cluster_vip

try {
    $clusterInfo = Invoke-RestMethod -Uri $clusterInfoUri -Method GET -Headers $clusterHeaders -SkipCertificateCheck
    $clusterName = $clusterInfo.name
    $clusterUuid = $clusterInfo.uuid
    
    Write-Host "  Γ£ô Cluster Name: $clusterName" -ForegroundColor Green
    Write-Host "  Γ£ô Cluster UUID: $clusterUuid" -ForegroundColor Green
} catch {
    Write-Host "  Γ£ù Failed to retrieve cluster information: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Get CVM IP if not provided
if (-not $CVMIP) {
    Write-Host "`nRetrieving CVM IP..." -ForegroundColor Yellow
    
    $hostsUri = "https://{0}:9440/PrismGateway/services/rest/v2.0/hosts" -f $cluster_vip
    
    try {
        $hostsInfo = Invoke-RestMethod -Uri $hostsUri -Method GET -Headers $clusterHeaders -SkipCertificateCheck
        $CVMIP = $hostsInfo.entities[0].service_vmexternal_ip
        
        Write-Host "  Γ£ô Detected CVM IP: $CVMIP" -ForegroundColor Green
    } catch {
        Write-Host "  Γ£ù Failed to retrieve CVM IP automatically." -ForegroundColor Red
        Write-Host "  Please specify -CVMIP parameter." -ForegroundColor Yellow
        exit 1
    }
}

# Step 2: Connect to CVM via SSH and register
Write-Host "`nStep 2: Connecting to Cluster CVM via SSH ($CVMIP)..." -ForegroundColor Yellow

$securePassword = ConvertTo-SecureString $ClusterCVMSSHPassword -AsPlainText -Force
$sshCredential = New-Object System.Management.Automation.PSCredential($ClusterCVMSSHUsername, $securePassword)

try {
    $sshSession = New-CompatibleSSHSession -ComputerName $CVMIP -Credential $sshCredential
    
    if ($sshSession) {
        Write-Host "  Γ£ô SSH connection established successfully!" -ForegroundColor Green
        
        # Execute NCLI command
        Write-Host "`nStep 3: Executing NCLI registration command..." -ForegroundColor Yellow
        
        # Source Nutanix environment and run ncli command
        $ncliCommand = "bash -c `"source /etc/profile.d/nutanix_env.sh 2>/dev/null; ncli multicluster add-to-multicluster external-ip-address-or-svm-ips=$PrismCentralIP username=$PrismCentralUsername password='$PrismCentralPassword'`""
        
        Write-Host "  Registering cluster to Prism Central..." -ForegroundColor Cyan
        Write-Host "  Command: ncli multicluster add-to-multicluster external-ip-address-or-svm-ips=$PrismCentralIP username=$PrismCentralUsername password=***" -ForegroundColor Gray
        
        $ncliResult = Invoke-SSHCommand -SessionId $sshSession.SessionId -Command $ncliCommand -TimeOut 120
        
        Write-Host "`n  Command Output:" -ForegroundColor Cyan
        Write-Host "  $($ncliResult.Output)" -ForegroundColor White
        
        if ($ncliResult.Error) {
            Write-Host "`n  Error Output:" -ForegroundColor Yellow
            Write-Host "  $($ncliResult.Error)" -ForegroundColor DarkYellow
        }
        
        Write-Host "`n  Exit Status: $($ncliResult.ExitStatus)" -ForegroundColor Gray
        
        if ($ncliResult.ExitStatus -eq 0 -or $ncliResult.Output -match "Status.*:.*true" -or $ncliResult.Output -match "successfully") {
            Write-Host "`n=== Registration Successful ===" -ForegroundColor Green
            Write-Host "Cluster '$clusterName' has been registered to Prism Central." -ForegroundColor Green
        } elseif ($ncliResult.Output -match "already" -or $ncliResult.Error -match "already") {
            Write-Host "`n=== Cluster Already Registered ===" -ForegroundColor Yellow
            Write-Host "Cluster '$clusterName' is already registered to a Prism Central." -ForegroundColor Yellow
        } elseif ($ncliResult.Output -match "not compatible" -or $ncliResult.Output -match "version.*not.*compatible" -or $ncliResult.Output -match "compatible.*version") {
            Write-Host "`n=== Registration Failed ΓÇö Version Incompatibility ===" -ForegroundColor Red
            Write-Host "  $($ncliResult.Output)" -ForegroundColor Red
            Write-Host "  Resolution: Upgrade Prism Central to match or exceed the AOS version before registering." -ForegroundColor Yellow
            Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
            exit 1
        } else {
            Write-Host "`n=== Registration Failed ===" -ForegroundColor Red
            Write-Host "  NCLI exited with status $($ncliResult.ExitStatus). Output:" -ForegroundColor Red
            Write-Host "  $($ncliResult.Output)" -ForegroundColor Red
            Write-Host "  Please resolve the error above before continuing." -ForegroundColor Yellow
            Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
            exit 1
        }
        
        # Clean up SSH session
        Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
        Write-Host "`nSSH session closed." -ForegroundColor Gray
        
    } else {
        Write-Host "  Γ£ù Failed to establish SSH connection to CVM!" -ForegroundColor Red
        exit 1
    }
    
} catch {
    Write-Host "  Γ£ù SSH connection failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "`nPlease verify:" -ForegroundColor Yellow
    Write-Host "1. CVM IP is correct: $CVMIP" -ForegroundColor White
    Write-Host "2. SSH credentials are correct (username: $ClusterCVMSSHUsername)" -ForegroundColor White
    Write-Host "3. SSH is enabled on the CVM" -ForegroundColor White
    Write-Host "4. Network connectivity between your machine and CVM" -ForegroundColor White
    exit 1
}

# Step 4: Verify registration in Prism Central
Write-Host "`nStep 4: Verifying registration in Prism Central..." -ForegroundColor Yellow
Write-Host "  Waiting 20 seconds for registration to sync..." -ForegroundColor Gray
Start-Sleep -Seconds 20

$pcCredString = $PrismCentralUsername + ":" + $PrismCentralPassword
$pcBase64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pcCredString))
$pcHeaders = @{
    "Authorization" = "Basic $pcBase64Auth"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
}

$verifyUri = "https://{0}:9440/api/nutanix/v3/clusters/list" -f $PrismCentralIP
$verifyBody = @{ kind = "cluster"; length = 250 } | ConvertTo-Json

try {
    $verifyResp = Invoke-RestMethod -Uri $verifyUri -Method POST -Headers $pcHeaders -Body $verifyBody -SkipCertificateCheck
    
    $registeredCluster = $verifyResp.entities | Where-Object { 
        $_.spec.name -eq $clusterName -or 
        $_.metadata.uuid -eq $clusterUuid -or
        $_.spec.resources.network.external_ip -eq $cluster_vip
    }
    
    if ($registeredCluster) {
        Write-Host "`n=== Registration Verified in Prism Central ===" -ForegroundColor Green
        Write-Host "  Γ£ô Cluster Name: $($registeredCluster.spec.name)" -ForegroundColor Green
        Write-Host "  Γ£ô Cluster UUID: $($registeredCluster.metadata.uuid)" -ForegroundColor Green
        Write-Host "  Γ£ô Cluster VIP: $cluster_vip" -ForegroundColor Green
        Write-Host "  Γ£ô Prism Central: $PrismCentralIP" -ForegroundColor Green
        Write-Host "  Γ£ô Status: Successfully registered and visible" -ForegroundColor Green
    } else {
        Write-Host "`n  Cluster not yet visible in Prism Central." -ForegroundColor Yellow
        Write-Host "  This is normal - registration sync can take 5-10 minutes." -ForegroundColor Yellow
        Write-Host "`n  To verify manually:" -ForegroundColor Cyan
        Write-Host "  1. Log into Prism Central: https://$PrismCentralIP`:9440" -ForegroundColor White
        Write-Host "  2. Go to: Settings (gear icon) > Availability Zones" -ForegroundColor White
        Write-Host "  3. Look for cluster: $clusterName" -ForegroundColor White
    }
} catch {
    Write-Host "`n  Could not verify registration via API." -ForegroundColor Yellow
    Write-Host "  Please check Prism Central UI manually: https://$PrismCentralIP`:9440" -ForegroundColor Yellow
}

Write-Host "`n" + ("=" * 80) -ForegroundColor Cyan
Write-Host "REGISTRATION SUMMARY" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Cluster Name:    $clusterName" -ForegroundColor White
Write-Host "Cluster VIP:     $cluster_vip" -ForegroundColor White
Write-Host "CVM IP Used:     $CVMIP" -ForegroundColor White
Write-Host "Prism Central:   $PrismCentralIP" -ForegroundColor White
Write-Host "`nNote: Full cluster sync and data collection may take 5-10 minutes." -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan

# ── Set Data Service IP ───────────────────────────────────────────────────────
# Read data_service_ip from config file. If present, wait 60 s and apply it via
# the v4.2 clustermgmt API so the pipeline needs no separate script call.

$dataServiceIP = $null
if ($config.PSObject.Properties['network'] -and
    $config.network.PSObject.Properties['data_service_ip'] -and
    $config.network.data_service_ip) {
    $dataServiceIP = $config.network.data_service_ip
}

if (-not $dataServiceIP) {
    Write-Host "`n[INFO] 'network.data_service_ip' not set in config — skipping Data Service IP step." -ForegroundColor Yellow
    exit 0
}

$pcUrl = "https://{0}:9440" -f $PrismCentralIP
$pcBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${PrismCentralUsername}:${PrismCentralPassword}"))
$pcApiHeaders = @{
    'Authorization' = "Basic $pcBase64"
    'Content-Type'  = 'application/json'
    'Accept'        = 'application/json'
}

Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "SET DATA SERVICE IP" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "  Target cluster : $clusterName"      -ForegroundColor White
Write-Host "  Data Svc IP    : $dataServiceIP"     -ForegroundColor White
Write-Host "  Waiting 60 seconds for PC sync before applying..." -ForegroundColor Gray
Start-Sleep -Seconds 60

# Step A: Find cluster extId in PC (v4.2 API)
Write-Host "`n  [1/4] Fetching cluster list from Prism Central..." -ForegroundColor Yellow
$clusterExtId = $null
try {
    $listResp = Invoke-RestMethod -Uri "$pcUrl/api/clustermgmt/v4.2/config/clusters" `
        -Method GET -Headers $pcApiHeaders -SkipCertificateCheck -TimeoutSec 30
    $clusters = if ($listResp.data) { $listResp.data } else { @($listResp) }
    $targetCluster = $clusters | Where-Object { $_.name -eq $clusterName } | Select-Object -First 1
    if (-not $targetCluster) {
        Write-Host "  [WARN] Cluster '$clusterName' not yet visible in PC cluster list — skipping Data Service IP." -ForegroundColor Yellow
        Write-Host "         Set it manually via: .\Set-DataServiceIP.ps1 -ConfigFile $ConfigFile" -ForegroundColor Gray
        exit 0
    }
    $clusterExtId = $targetCluster.extId
    Write-Host "  [OK]  Found cluster extId: $clusterExtId" -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Could not query PC cluster list: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "         Set Data Service IP manually via: .\Set-DataServiceIP.ps1 -ConfigFile $ConfigFile" -ForegroundColor Gray
    exit 0
}

# Step B: GET cluster object + ETag
Write-Host "  [2/4] Fetching cluster config + ETag..." -ForegroundColor Yellow
$clusterDetailUrl = "$pcUrl/api/clustermgmt/v4.2/config/clusters/$clusterExtId"
$etag = $null
$clusterObj = $null
try {
    $getResp = Invoke-WebRequest -Uri $clusterDetailUrl -Method GET -Headers $pcApiHeaders `
        -SkipCertificateCheck -TimeoutSec 30
    $etag = [string]($getResp.Headers['ETag']  | Select-Object -First 1)
    if (-not $etag) { $etag = [string]($getResp.Headers['Etag'] | Select-Object -First 1) }
    $clusterObj = $getResp.Content | ConvertFrom-Json
    Write-Host "  [OK]  ETag retrieved" -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Could not fetch cluster detail: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "         Set Data Service IP manually via: .\Set-DataServiceIP.ps1 -ConfigFile $ConfigFile" -ForegroundColor Gray
    exit 0
}

# Step C: Build PUT body
Write-Host "  [3/4] Building PUT payload..." -ForegroundColor Yellow
$putBody = if ($clusterObj.data) { $clusterObj.data } else { $clusterObj }

# Remove read-only fields that PC rejects on PUT
if ($putBody.PSObject.Properties['config'] -and $putBody.config) {
    foreach ($field in @('faultToleranceState', 'redundancyFactor', 'buildInfo', 'clusterArch')) {
        if ($putBody.config.PSObject.Properties[$field]) {
            $putBody.config.PSObject.Properties.Remove($field)
        }
    }
}
if (-not $putBody.network) {
    $putBody | Add-Member -MemberType NoteProperty -Name 'network' -Value ([PSCustomObject]@{})
}
$newDSIP = [PSCustomObject]@{
    '$reserved'   = [PSCustomObject]@{ '$fv' = 'v1.r0' }
    '$objectType' = 'common.v1.config.IPAddress'
    ipv4          = [PSCustomObject]@{
        '$reserved'   = [PSCustomObject]@{ '$fv' = 'v1.r0' }
        '$objectType' = 'common.v1.config.IPv4Address'
        value         = $dataServiceIP
        prefixLength  = 32
    }
}
if ($putBody.network.PSObject.Properties['externalDataServiceIp']) {
    $putBody.network.externalDataServiceIp = $newDSIP
} else {
    $putBody.network | Add-Member -MemberType NoteProperty -Name 'externalDataServiceIp' -Value $newDSIP
}
$putBodyJson = $putBody | ConvertTo-Json -Depth 20

# Step D: PUT via HttpClient (bypasses .NET ETag quoting enforcement)
Write-Host "  [4/4] Applying Data Service IP $dataServiceIP..." -ForegroundColor Yellow
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.ServerCertificateCustomValidationCallback =
    [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
$httpClient = [System.Net.Http.HttpClient]::new($handler)
try {
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Put, $clusterDetailUrl)
    $contentBytes  = [System.Text.Encoding]::UTF8.GetBytes($putBodyJson)
    $req.Content   = [System.Net.Http.ByteArrayContent]::new($contentBytes)
    $req.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
    $req.Headers.TryAddWithoutValidation('Authorization', "Basic $pcBase64") | Out-Null
    $req.Headers.TryAddWithoutValidation('Accept',        'application/json') | Out-Null
    $req.Headers.TryAddWithoutValidation('If-Match',      $etag)              | Out-Null

    $httpResp = $httpClient.SendAsync($req).GetAwaiter().GetResult()
    $respBody = $httpResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    if (-not $httpResp.IsSuccessStatusCode) {
        Write-Host "  [WARN] PUT failed (HTTP $([int]$httpResp.StatusCode)): $respBody" -ForegroundColor Yellow
        Write-Host "         Set Data Service IP manually via: .\Set-DataServiceIP.ps1 -ConfigFile $ConfigFile" -ForegroundColor Gray
        exit 0
    }

    $putResp = $respBody | ConvertFrom-Json
    $taskId  = if ($putResp.data.PSObject.Properties['extId']) { $putResp.data.extId } else { $putResp.taskExtId }

    if ($taskId) {
        Write-Host "  [OK]  Task submitted: $taskId — polling..." -ForegroundColor Green
        $taskUrl  = "$pcUrl/api/prism/v4.0/config/tasks/$taskId"
        $deadline = (Get-Date).AddMinutes(5)
        $done     = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            try {
                $taskResp  = Invoke-RestMethod -Uri $taskUrl -Method GET -Headers $pcApiHeaders -SkipCertificateCheck -TimeoutSec 15
                $taskState = $taskResp.data.status
                Write-Host "         Task status: $taskState" -ForegroundColor Gray
                if ($taskState -in @('SUCCEEDED','COMPLETED')) { $done = $true; break }
                if ($taskState -in @('FAILED','ABORTED','CANCELED')) {
                    Write-Host "  [WARN] Task $taskState — check PC task log." -ForegroundColor Yellow
                    break
                }
            } catch {}
        }
        if ($done) {
            Write-Host "  [OK]  Data Service IP set successfully." -ForegroundColor Green
        } elseif (-not $done) {
            Write-Host "  [WARN] Task did not complete within 5 min — check PC task list." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [OK]  Data Service IP applied (no async task returned)." -ForegroundColor Green
    }
} catch {
    Write-Host "  [WARN] Failed to set Data Service IP: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "         Set it manually via: .\Set-DataServiceIP.ps1 -ConfigFile $ConfigFile" -ForegroundColor Gray
} finally {
    $httpClient.Dispose()
}

Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Green
Write-Host "  Data Service IP : $dataServiceIP  →  applied to cluster '$clusterName'" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Green
exit 0
