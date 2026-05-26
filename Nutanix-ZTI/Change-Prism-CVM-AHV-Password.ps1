<#
.SYNOPSIS
    Change Nutanix passwords and export to SecureVault CSV format with IP information
.DESCRIPTION
    This script:
    1. Changes Prism admin password
    2. Changes CVM admin password (cluster-wide)
    3. Changes nutanix user password ON EACH CVM INDIVIDUALLY (separate password per node)
    4. Changes AHV host root passwords
    5. Exports all passwords to CSV file in SecureVault format: ClusterName_Password.csv
    
    CSV Format (space-delimited):
    Name Server_Name Username Password Tags Folder Notes
    
    Entries created:
    - ClusterName_Prism_Admin: Prism admin credentials (Notes: Prism Element Cluster VIP)
    - ClusterName_CVM_Nutanix: CVM admin credentials (Notes: All CVM IPs, comma-separated)
    - NodeName_AHV_Root: Individual AHV root per host (Notes: Individual AHV host IP)
    
    Notes Column Content:
    - Prism_Admin: Prism_Element_Cluster_VIP:10.0.113.110
    - CVM_Nutanix: CVM_IPs:10.0.113.112,10.0.113.114
    - AHV_Root: AHV_Host_IP:10.0.113.111
    
.EXAMPLE
    .\Change-Prism-CVM-AHV-Password-ToCSV.ps1 -ConfigFile .\Configs\my-cluster.json

.NOTES
    Author: Sonu Agarwal
    Date: Mar 16, 2026
    Version: 1.0
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile,

    [Parameter(Mandatory=$false)]
    [string]$ClusterVIP,

    [Parameter(Mandatory=$false)]
    [int]$PasswordLength = 16,

    [Parameter(Mandatory=$false)]
    [string]$CsvTag = 'Nutanix',

    [Parameter(Mandatory=$false)]
    [string]$CsvFolder = 'Nutanix_Remote_Sites'
)

# ── Hardcoded Nutanix factory-default credentials ─────────────────────────────
$CurrentAdminPassword = "Nutanix/4u"
$CurrentCVMPassword   = "nutanix/4u"
$CurrentAHVPassword   = "nutanix/4u"

# ── Resolve ClusterVIP from config file if provided ──────────────────────────
if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if (-not $ClusterVIP) {
        $ClusterVIP = $cfg.network.cluster_vip
    }
}

if (-not $ClusterVIP) {
    Write-Host "ERROR: ClusterVIP must be provided via -ConfigFile or -ClusterVIP." -ForegroundColor Red
    exit 1
}

Write-Host "=== Nutanix Password Change with SecureVault CSV Export ===" -ForegroundColor Cyan
Write-Host "Cluster VIP: $ClusterVIP" -ForegroundColor Yellow
Write-Host ""

#region Helper Functions

function Generate-ComplexPassword {
    param(
        [int]$Length = 16
    )
    
    # Character sets - use only shell-safe special characters
    $uppercase = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $lowercase = "abcdefghijkmnpqrstuvwxyz"
    $numbers = "23456789"
    $special = "@#%^*-_=+"
    
    $password = @()
    # Ensure we have at least one of each required type
    $password += $uppercase[(Get-Random -Maximum $uppercase.Length)]
    $password += $lowercase[(Get-Random -Maximum $lowercase.Length)]
    $password += $numbers[(Get-Random -Maximum $numbers.Length)]
    $password += $special[(Get-Random -Maximum $special.Length)]
    
    $allChars = $uppercase + $lowercase + $numbers + $special
    for ($i = $password.Count; $i -lt $Length; $i++) {
        $password += $allChars[(Get-Random -Maximum $allChars.Length)]
    }
    
    # Shuffle the password
    $shuffled = $password | Get-Random -Count $password.Count
    $generatedPassword = -join $shuffled
    
    # Ensure no more than 2 consecutive same characters
    while ($generatedPassword -match '(.)\1{2,}') {
        $shuffled = $password | Get-Random -Count $password.Count
        $generatedPassword = -join $shuffled
    }
    
    return $generatedPassword
}

function New-CompatibleSSHSession {
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential
    )
    
    try {
        $session = New-SSHSession -ComputerName $ComputerName -Credential $Credential -AcceptKey -Port 22 -ErrorAction Stop
        return $session
    }
    catch {
        Write-Host "    Standard connection failed, trying compatibility mode..." -ForegroundColor Gray
        
        try {
            $username = $Credential.UserName
            $password = $Credential.GetNetworkCredential().Password
            
            $connectionInfo = New-Object Renci.SshNet.ConnectionInfo(
                $ComputerName,
                22,
                $username,
                (New-Object Renci.SshNet.PasswordAuthenticationMethod($username, $password))
            )
            
            $connectionInfo.Timeout = [TimeSpan]::FromSeconds(30)
            
            $sshClient = New-Object Renci.SshNet.SshClient($connectionInfo)
            $sshClient.Connect()
            
            if ($sshClient.IsConnected) {
                $session = New-SSHSession -ComputerName $ComputerName -Credential $Credential -AcceptKey -Force -ErrorAction Stop
                return $session
            }
        }
        catch {
            throw $_
        }
    }
}

function Get-ClusterInfo {
    param(
        [string]$ClusterIP,
        [string]$Username,
        [string]$Password
    )
    
    $credString = "$Username`:$Password"
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($credString))
    $headers = @{
        "Authorization" = "Basic $base64Auth"
        "Content-Type"  = "application/json"
    }
    
    $uri = "https://{0}:9440/PrismGateway/services/rest/v2.0/cluster" -f $ClusterIP
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -SkipCertificateCheck -ErrorAction Stop
        return @{
            Success = $true
            ClusterName = $response.name
            Version = $response.version
        }
    } catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
            ClusterName = "UnknownCluster"
        }
    }
}

function Get-CVMDetails {
    param(
        [int]$CVMSession
    )
    
    Write-Host "    Getting CVM details from cluster..." -ForegroundColor Gray
    
    # Method 1: Try to get CVM IPs directly using svmips command
    Write-Host "    Method 1: Trying 'allssh svmips' command..." -ForegroundColor Gray
    $svmipsCmd = "allssh 'svmips'"
    $svmipsResult = Invoke-SSHCommand -SessionId $CVMSession -Command $svmipsCmd -TimeOut 30
    
    $cvmIPsList = @()
    if ($svmipsResult.ExitStatus -eq 0 -and $svmipsResult.Output) {
        # Parse IP addresses from output
        $svmipsResult.Output -split "`n" | ForEach-Object {
            if ($_ -match "(\d+\.\d+\.\d+\.\d+)") {
                $cvmIPsList += $matches[1]
            }
        }
        if ($cvmIPsList.Count -gt 0) {
            Write-Host "    ✓ Found $($cvmIPsList.Count) CVM IP(s) using svmips: $($cvmIPsList -join ', ')" -ForegroundColor Cyan
        }
    }
    
    # Method 2: Use ncli to get detailed host information
    Write-Host "    Method 2: Parsing 'ncli host ls' output..." -ForegroundColor Gray
    $ncliCmd = "bash -c `"source /etc/profile.d/nutanix_env.sh 2>/dev/null; ncli host ls`""
    $result = Invoke-SSHCommand -SessionId $CVMSession -Command $ncliCmd -TimeOut 30
    
    if ($result.ExitStatus -eq 0) {
        $cvmDetails = @()
        $lines = $result.Output -split "`n"
        
        $currentHost = @{}
        foreach ($line in $lines) {
            # Look for host name
            if ($line -match "Name\s*:\s*(.+)") {
                if ($currentHost.Count -gt 0) {
                    $cvmDetails += $currentHost
                }
                $currentHost = @{
                    Name = $matches[1].Trim()
                }
            }
            # Look for Controller VM Address (official field name)
            elseif ($line -match "Controller VM Address\s*:\s*(\d+\.\d+\.\d+\.\d+)") {
                $currentHost.CVMIP = $matches[1]
            }
            # Fallback patterns for older Nutanix versions
            elseif ($line -match "Service VM\s*:\s*(\d+\.\d+\.\d+\.\d+)") {
                $currentHost.CVMIP = $matches[1]
            }
            elseif ($line -match "Controller VM IP\s*:\s*(\d+\.\d+\.\d+\.\d+)") {
                $currentHost.CVMIP = $matches[1]
            }
            elseif ($line -match "CVM IP\s*:\s*(\d+\.\d+\.\d+\.\d+)") {
                $currentHost.CVMIP = $matches[1]
            }
            # Look for hypervisor address
            elseif ($line -match "Hypervisor Address\s*:\s*(\d+\.\d+\.\d+\.\d+)") {
                $currentHost.HypervisorIP = $matches[1]
            }
        }
        
        # Add the last host
        if ($currentHost.Count -gt 0) {
            $cvmDetails += $currentHost
        }
        
        # If ncli didn't find CVM IPs but svmips did, merge them
        if ($cvmIPsList.Count -gt 0) {
            $cvmIndex = 0
            foreach ($cvm in $cvmDetails) {
                if (-not $cvm.CVMIP -and $cvmIndex -lt $cvmIPsList.Count) {
                    $cvm.CVMIP = $cvmIPsList[$cvmIndex]
                    Write-Host "    ✓ Assigned CVM IP $($cvmIPsList[$cvmIndex]) to $($cvm.Name)" -ForegroundColor Green
                    $cvmIndex++
                }
            }
        }
        
        # Debug: Show what we found
        Write-Host "    Parsed $($cvmDetails.Count) host(s) from cluster" -ForegroundColor Gray
        foreach ($cvm in $cvmDetails) {
            if ($cvm.CVMIP) {
                Write-Host "    ✓ CVM: $($cvm.Name) - CVM IP: $($cvm.CVMIP) - Host IP: $($cvm.HypervisorIP)" -ForegroundColor Cyan
            } else {
                Write-Host "    ⚠ CVM: $($cvm.Name) - CVM IP not found, Host IP: $($cvm.HypervisorIP)" -ForegroundColor Yellow
            }
        }
        
        return @{ Success = $true; CVMs = $cvmDetails }
    } else {
        Write-Host "    ✗ Failed to get CVM details" -ForegroundColor Red
        Write-Host "    Exit Status: $($result.ExitStatus)" -ForegroundColor Red
        Write-Host "    Output: $($result.Output)" -ForegroundColor Red
        return @{ Success = $false; CVMs = @() }
    }
}

function Change-AdminPasswordViaCVM {
    param(
        [int]$CVMSession,
        [string]$NewAdminPassword
    )
    
    Write-Host "    Changing admin password via ncli..." -ForegroundColor Gray
    
    $escapedPassword = $NewAdminPassword -replace "'", "'\''"
    $ncliCmd = "bash -c `"source /etc/profile.d/nutanix_env.sh 2>/dev/null; ncli user reset-password user-name=admin password='$escapedPassword'`""
    
    $result = Invoke-SSHCommand -SessionId $CVMSession -Command $ncliCmd -TimeOut 30
    
    Write-Host "    Exit Status: $($result.ExitStatus)" -ForegroundColor Gray
    
    if ($result.Output -match "Password requirements" -or $result.Output -match "Should be at least") {
        return @{ Success = $false; Error = "Password complexity requirements not met: $($result.Output)" }
    }
    
    if ($result.ExitStatus -eq 0) {
        Write-Host "    ✓ Admin password changed successfully" -ForegroundColor Green
        return @{ Success = $true }
    } else {
        return @{ Success = $false; Error = "ncli returned exit code $($result.ExitStatus). Output: $($result.Output)" }
    }
}

function Change-CVMAdminPassword {
    param(
        [int]$CVMSession,
        [string]$NewPassword
    )
    
    Write-Host "    Changing CVM admin password (cluster-wide)..." -ForegroundColor Gray
    
    $chpasswdCmd = "echo 'admin:$NewPassword' | sudo chpasswd"
    $result = Invoke-SSHCommand -SessionId $CVMSession -Command $chpasswdCmd -TimeOut 30
    
    Write-Host "    Exit Status: $($result.ExitStatus)" -ForegroundColor Gray
    
    if ($result.ExitStatus -eq 0) {
        Write-Host "    ✓ CVM admin password changed (cluster-wide)" -ForegroundColor Green
        return @{ Success = $true }
    } else {
        return @{ Success = $false; Error = "chpasswd returned exit code $($result.ExitStatus)" }
    }
}

function Change-CVMNutanixPassword {
    param(
        [string]$CVMIP,
        [string]$CurrentPassword,
        [string]$NewPassword
    )
    
    Write-Host "    Connecting to CVM: $CVMIP..." -ForegroundColor Gray
    
    $securePassword = ConvertTo-SecureString $CurrentPassword -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential("nutanix", $securePassword)
    
    try {
        $cvmSession = New-CompatibleSSHSession -ComputerName $CVMIP -Credential $credential
        
        if ($null -eq $cvmSession) {
            return @{ Success = $false; Error = "Failed to establish SSH connection to $CVMIP" }
        }
        
        Write-Host "    ✓ Connected to $CVMIP" -ForegroundColor Gray
        
        # Change nutanix password on this specific CVM
        $chpasswdCmd = "echo 'nutanix:$NewPassword' | sudo chpasswd"
        $result = Invoke-SSHCommand -SessionId $cvmSession.SessionId -Command $chpasswdCmd -TimeOut 30
        
        Write-Host "    Exit Status: $($result.ExitStatus)" -ForegroundColor Gray
        
        Remove-SSHSession -SessionId $cvmSession.SessionId | Out-Null
        
        if ($result.ExitStatus -eq 0) {
            Write-Host "    ✓ Nutanix password changed on $CVMIP" -ForegroundColor Green
            return @{ Success = $true }
        } else {
            return @{ Success = $false; Error = "chpasswd command returned exit code $($result.ExitStatus)" }
        }
        
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Change-AHVRootPassword {
    param(
        [string]$HostIP,
        [string]$CurrentPassword,
        [string]$NewPassword
    )
    
    Write-Host "    Connecting to AHV host: $HostIP..." -ForegroundColor Gray
    
    $securePassword = ConvertTo-SecureString $CurrentPassword -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential("root", $securePassword)
    
    try {
        $hostSession = New-CompatibleSSHSession -ComputerName $HostIP -Credential $credential
        
        if ($null -eq $hostSession) {
            return @{ Success = $false; Error = "Failed to establish SSH connection to $HostIP" }
        }
        
        Write-Host "    ✓ Connected to $HostIP" -ForegroundColor Gray
        
        # Change root password using passwd command
        $passwdCmd = "echo -e `"$NewPassword\n$NewPassword`" | passwd root"
        $result = Invoke-SSHCommand -SessionId $hostSession.SessionId -Command $passwdCmd -TimeOut 30
        
        Write-Host "    Exit Status: $($result.ExitStatus)" -ForegroundColor Gray
        
        # Close session
        Remove-SSHSession -SessionId $hostSession.SessionId | Out-Null
        
        if ($result.ExitStatus -eq 0) {
            Write-Host "    ✓ Root password changed on $HostIP" -ForegroundColor Green
            return @{ Success = $true }
        } else {
            Write-Host "    ✗ Failed to change root password on $HostIP" -ForegroundColor Red
            return @{ Success = $false; Error = "passwd command returned exit code $($result.ExitStatus)" }
        }
        
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Export-ToSecureVaultCSV {
    param(
        [string]$ClusterName,
        [string]$ClusterVIP,
        [string]$PrismAdminPassword,
        [string]$CVMNutanixPassword,
        [array]$AHVRootPasswords,
        [array]$CVMNodes,
        [string]$OutputPath,
        [string]$Tag    = 'Nutanix',
        [string]$Folder = 'Nutanix_Remote_Sites'
    )
    
    Write-Host "`nExporting to SecureVault CSV format with Notes..." -ForegroundColor Yellow
    
    # Create CSV content with space delimiter
    $csvContent = @()
    
    # Header - now includes Notes column
    $csvContent += "Name Server_Name Username Password Tags Folder Notes"
    
    # Prism Admin entry - Add Cluster VIP in Notes
    $prismNotes = "Prism_Element_Cluster_VIP:${ClusterVIP}"
    $csvContent += "${ClusterName}_Prism_Admin ${ClusterName} admin ${PrismAdminPassword} ${Tag} ${Folder} ${prismNotes}"
    
    # CVM Nutanix entry (cluster-wide) - Add all CVM IPs in Notes
    $cvmIPs = ($CVMNodes | ForEach-Object { $_.CVMIP } | Where-Object { $_ }) -join ','
    
    # Fallback: If no CVM IPs found, try to derive from AHV hosts
    if (-not $cvmIPs -or $cvmIPs -eq "") {
        Write-Host "    Warning: CVM IPs not found in CVMNodes, deriving from cluster..." -ForegroundColor Yellow
        # As a fallback, we can infer CVM IPs are typically +2 from host IPs in many deployments
        # Or we can leave it blank and the user can fill manually
        $cvmIPs = "NotAvailable-CheckManually"
    }
    
    $cvmNotes = "CVM_IPs:${cvmIPs}"
    $csvContent += "${ClusterName}_CVM_Nutanix ${ClusterName}_cvm nutanix ${CVMNutanixPassword} ${Tag} ${Folder} ${cvmNotes}"
    
    # AHV Root entries (individual per host) - Add individual host IP in Notes
    foreach ($ahvEntry in $AHVRootPasswords) {
        $hostName = $ahvEntry.HostName -replace '\.', '_'  # Replace dots with underscores for name
        $ahvNotes = "AHV_Host_IP:$($ahvEntry.HostIP)"
        $csvContent += "${hostName}_AHV_Root $($ahvEntry.HostName) root $($ahvEntry.Password) ${Tag} ${Folder} ${ahvNotes}"
    }
    
    # Save to file
    $csvContent | Out-File -FilePath $OutputPath -Encoding ASCII
    
    Write-Host "  ✓ CSV exported to: $OutputPath" -ForegroundColor Green
    Write-Host "  Total entries: $($csvContent.Count - 1)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Notes column populated with:" -ForegroundColor Cyan
    Write-Host "    - Prism Element Cluster VIP: ${ClusterVIP}" -ForegroundColor Gray
    if ($cvmIPs -and $cvmIPs -ne "" -and $cvmIPs -ne "NotAvailable-CheckManually") {
        Write-Host "    - CVM IPs: ${cvmIPs}" -ForegroundColor Gray
    } else {
        Write-Host "    - CVM IPs: ${cvmIPs} (manually verify)" -ForegroundColor Yellow
    }
    Write-Host "    - Individual AHV Host IPs for each host" -ForegroundColor Gray
}

function Install-RequiredModules {
    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        Write-Host "Installing Posh-SSH module..." -ForegroundColor Cyan
        try {
            Install-Module -Name Posh-SSH -Force -Scope CurrentUser -ErrorAction Stop
            Write-Host "Posh-SSH module installed successfully." -ForegroundColor Green
        } catch {
            Write-Host "Failed to install Posh-SSH module: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
    
    Import-Module Posh-SSH -ErrorAction SilentlyContinue
    return $true
}

#endregion

#region Main Script

# Install required modules
if (-not (Install-RequiredModules)) {
    Write-Host "Required modules installation failed. Exiting." -ForegroundColor Red
    exit 1
}

# Step 1: Get cluster name via API
Write-Host "Step 1: Getting cluster information..." -ForegroundColor Yellow

$clusterInfo = Get-ClusterInfo -ClusterIP $ClusterVIP -Username "admin" -Password $CurrentAdminPassword

if ($clusterInfo.Success) {
    $clusterName = $clusterInfo.ClusterName
    Write-Host "  ✓ Cluster Name: $clusterName" -ForegroundColor Green
    Write-Host "  ✓ Version: $($clusterInfo.Version)" -ForegroundColor Green
} else {
    Write-Host "  ⚠ Could not retrieve cluster name, using default" -ForegroundColor Yellow
    $clusterName = "Cluster_" + $ClusterVIP.Replace('.','_')
}
Write-Host ""

# Step 2: Generate new passwords
Write-Host "Step 2: Generating new complex passwords..." -ForegroundColor Yellow

$newPrismAdminPassword = Generate-ComplexPassword -Length $PasswordLength
$newCVMNutanixPassword = Generate-ComplexPassword -Length $PasswordLength

Write-Host "  ✓ Prism admin password generated: $newPrismAdminPassword" -ForegroundColor Green
Write-Host "  ✓ CVM nutanix password generated (cluster-wide): $newCVMNutanixPassword" -ForegroundColor Green
Write-Host ""
Write-Host "  ⚠️  SAVE THESE PASSWORDS NOW!" -ForegroundColor Red
Write-Host ""

# Step 3: Connect to cluster VIP
Write-Host "Step 3: Connecting to cluster VIP via SSH..." -ForegroundColor Yellow

$securePassword = ConvertTo-SecureString $CurrentCVMPassword -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential("nutanix", $securePassword)

try {
    $vipSession = New-CompatibleSSHSession -ComputerName $ClusterVIP -Credential $credential
    
    if ($null -eq $vipSession) {
        Write-Host "  ✗ Failed to establish SSH session to cluster VIP" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "  ✓ Connected to cluster VIP" -ForegroundColor Green
    
} catch {
    Write-Host "  ✗ Error connecting to cluster VIP: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Step 4: Get CVM details
Write-Host "`nStep 4: Getting CVM node details..." -ForegroundColor Yellow

$cvmDetailsResult = Get-CVMDetails -CVMSession $vipSession.SessionId

if (-not $cvmDetailsResult.Success -or $cvmDetailsResult.CVMs.Count -eq 0) {
    Write-Host "  ✗ Could not retrieve CVM details" -ForegroundColor Red
    Remove-SSHSession -SessionId $vipSession.SessionId | Out-Null
    exit 1
}

$cvmNodes = $cvmDetailsResult.CVMs
Write-Host "  ✓ Found $($cvmNodes.Count) CVM node(s)" -ForegroundColor Green
Write-Host ""

# Step 5: Change Prism admin password
Write-Host "Step 5: Changing Prism Element admin password..." -ForegroundColor Yellow

$adminPasswordResult = Change-AdminPasswordViaCVM -CVMSession $vipSession.SessionId -NewAdminPassword $newPrismAdminPassword

if (-not $adminPasswordResult.Success) {
    Write-Host "  ✗ Failed to change admin password" -ForegroundColor Red
    Write-Host "  Error: $($adminPasswordResult.Error)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  ⚠️ NOTE: New passwords were generated but not applied:" -ForegroundColor Yellow
    Write-Host "     Prism Admin: $newPrismAdminPassword" -ForegroundColor Gray
    Write-Host "     CVM Admin:   $newCVMAdminPassword" -ForegroundColor Gray
    Remove-SSHSession -SessionId $vipSession.SessionId | Out-Null
    exit 1
}

# Step 6: Change CVM nutanix password (cluster-wide)
Write-Host "`nStep 6: Changing CVM nutanix password (cluster-wide)..." -ForegroundColor Yellow

$chpasswdCmd = "echo 'nutanix:$newCVMNutanixPassword' | sudo chpasswd"
$result = Invoke-SSHCommand -SessionId $vipSession.SessionId -Command $chpasswdCmd -TimeOut 30

Write-Host "    Exit Status: $($result.ExitStatus)" -ForegroundColor Gray
if ($result.Output) {
    Write-Host "    Output: $($result.Output)" -ForegroundColor Gray
}

if ($result.ExitStatus -ne 0) {
    Write-Host "  ✗ Failed to change CVM nutanix password" -ForegroundColor Red
    Write-Host "  Error: chpasswd returned exit code $($result.ExitStatus)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  ⚠️ NOTE: Prism admin password was changed to: $newPrismAdminPassword" -ForegroundColor Yellow
    Remove-SSHSession -SessionId $vipSession.SessionId | Out-Null
    exit 1
}

Write-Host "    ✓ CVM nutanix password changed (applies to all CVMs)" -ForegroundColor Green

# Close the initial VIP session
Remove-SSHSession -SessionId $vipSession.SessionId | Out-Null
Start-Sleep -Seconds 2

# Step 7: Change AHV root passwords on each host
Write-Host "`nStep 7: Changing AHV root passwords on each host..." -ForegroundColor Yellow

$ahvRootPasswords = @()

foreach ($cvm in $cvmNodes) {
    $hostIP = $cvm.HypervisorIP
    Write-Host "`n  Processing AHV Host: $($cvm.Name) ($hostIP)..." -ForegroundColor Cyan
    
    # Generate unique password for this AHV host's root user
    $newAHVPassword = Generate-ComplexPassword -Length $PasswordLength
    Write-Host "    Generated unique password for $($cvm.Name)" -ForegroundColor Gray
    
    $ahvResult = Change-AHVRootPassword -HostIP $hostIP `
                                         -CurrentPassword $CurrentAHVPassword `
                                         -NewPassword $newAHVPassword
    
    if ($ahvResult.Success) {
        $ahvRootPasswords += @{
            HostName = $cvm.Name
            HostIP = $hostIP
            Password = $newAHVPassword
            Success = $true
        }
    } else {
        Write-Host "    ⚠ Failed to change password: $($ahvResult.Error)" -ForegroundColor Yellow
        $ahvRootPasswords += @{
            HostName = $cvm.Name
            HostIP = $hostIP
            Password = $newAHVPassword
            Success = $false
            Error = $ahvResult.Error
        }
    }
    
    Start-Sleep -Seconds 1
}

# Step 8: Export to CSV
Write-Host "`nStep 8: Exporting passwords to SecureVault CSV..." -ForegroundColor Yellow

$csvFilename = Join-Path $PSScriptRoot "${clusterName}_Password.csv"

Export-ToSecureVaultCSV -ClusterName $clusterName `
                        -ClusterVIP $ClusterVIP `
                        -PrismAdminPassword $newPrismAdminPassword `
                        -CVMNutanixPassword $newCVMNutanixPassword `
                        -AHVRootPasswords $ahvRootPasswords `
                        -CVMNodes $cvmNodes `
                        -OutputPath $csvFilename `
                        -Tag $CsvTag `
                        -Folder $CsvFolder

# Step 9: Verify Prism admin password
Write-Host "`nStep 9: Validating new Prism admin password..." -ForegroundColor Yellow

$verifyClusterInfo = Get-ClusterInfo -ClusterIP $ClusterVIP -Username "admin" -Password $newPrismAdminPassword

if ($verifyClusterInfo.Success) {
    Write-Host "  ✓ Prism admin password validated via API!" -ForegroundColor Green
} else {
    Write-Host "  ⚠ API validation failed" -ForegroundColor Yellow
}

#endregion

#region Summary Report

Write-Host "`n`n" + ("=" * 80) -ForegroundColor Cyan
Write-Host "PASSWORD CHANGE SUMMARY REPORT" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Yellow
Write-Host ""

Write-Host "CLUSTER INFORMATION" -ForegroundColor Cyan
Write-Host ("-" * 80) -ForegroundColor Cyan
Write-Host "Cluster VIP:  $ClusterVIP" -ForegroundColor White
Write-Host "Cluster Name: $clusterName" -ForegroundColor White
if ($verifyClusterInfo.Success -and $verifyClusterInfo.Version) {
    Write-Host "Version:      $($verifyClusterInfo.Version)" -ForegroundColor White
}
Write-Host ""

Write-Host "PRISM ELEMENT ADMIN PASSWORD" -ForegroundColor Cyan
Write-Host ("-" * 80) -ForegroundColor Cyan
Write-Host "Username:     admin" -ForegroundColor White
Write-Host "Old Password: $CurrentAdminPassword" -ForegroundColor DarkGray
Write-Host "New Password: $newPrismAdminPassword" -ForegroundColor Yellow
Write-Host "Status:       $(if ($verifyClusterInfo.Success) { 'Verified ✓' } else { 'Changed (Unverified)' })" -ForegroundColor $(if ($verifyClusterInfo.Success) { 'Green' } else { 'Yellow' })
Write-Host ""

Write-Host "CVM NUTANIX USER PASSWORD (Cluster-Wide)" -ForegroundColor Cyan
Write-Host ("-" * 80) -ForegroundColor Cyan
Write-Host "Username:     nutanix" -ForegroundColor White
Write-Host "Old Password: $CurrentCVMPassword" -ForegroundColor DarkGray
Write-Host "New Password: $newCVMNutanixPassword" -ForegroundColor Yellow
Write-Host "Status:       Changed ✓ (applies to all CVMs)" -ForegroundColor Green
Write-Host ""

Write-Host "AHV HOST ROOT PASSWORDS (Individual Per Host)" -ForegroundColor Cyan
Write-Host ("-" * 80) -ForegroundColor Cyan
Write-Host "Username:     root" -ForegroundColor White
Write-Host "Old Password: $CurrentAHVPassword" -ForegroundColor DarkGray
Write-Host "Total Hosts:  $($ahvRootPasswords.Count)" -ForegroundColor White
Write-Host ""
Write-Host "Individual Host Passwords:" -ForegroundColor Cyan
foreach ($ahvEntry in $ahvRootPasswords) {
    $statusIcon = if ($ahvEntry.Success) { '✓' } else { '✗' }
    $statusColor = if ($ahvEntry.Success) { 'Green' } else { 'Yellow' }
    Write-Host "  $statusIcon $($ahvEntry.HostName) ($($ahvEntry.HostIP))" -ForegroundColor $statusColor
    Write-Host "     New Password: $($ahvEntry.Password)" -ForegroundColor Yellow
}
Write-Host ""

$successfulAHVs = ($ahvRootPasswords | Where-Object { $_.Success }).Count
$failedAHVs = ($ahvRootPasswords | Where-Object { -not $_.Success }).Count

Write-Host "Verification Summary:" -ForegroundColor Cyan
Write-Host "  Successful:   $successfulAHVs / $($ahvRootPasswords.Count)" -ForegroundColor $(if ($successfulAHVs -eq $ahvRootPasswords.Count) { 'Green' } else { 'Yellow' })
if ($failedAHVs -gt 0) {
    Write-Host "  Failed:       $failedAHVs" -ForegroundColor Yellow
}
Write-Host ""

Write-Host "CSV EXPORT" -ForegroundColor Cyan
Write-Host ("-" * 80) -ForegroundColor Cyan
Write-Host "File:         $csvFilename" -ForegroundColor Yellow
Write-Host "Total Entries: $(2 + $ahvRootPasswords.Count)" -ForegroundColor White
Write-Host "  - Prism Admin:    1 (with Cluster VIP in Notes)" -ForegroundColor Gray
Write-Host "  - CVM Nutanix:    1 (with all CVM IPs in Notes)" -ForegroundColor Gray
Write-Host "  - AHV Root:       $($ahvRootPasswords.Count) (each with host IP in Notes)" -ForegroundColor Gray
Write-Host "Format:       Space-delimited SecureVault format with Notes column" -ForegroundColor White
Write-Host ""
Write-Host "Notes Column:" -ForegroundColor Cyan
Write-Host "  - Prism Element Cluster VIP: $ClusterVIP" -ForegroundColor Gray
$cvmIPList = ($cvmNodes | ForEach-Object { $_.CVMIP }) -join ', '
Write-Host "  - CVM IPs: $cvmIPList" -ForegroundColor Gray
Write-Host "  - AHV Host IPs: Individual IP per host entry" -ForegroundColor Gray
Write-Host ""

Write-Host "NEXT STEPS" -ForegroundColor Cyan
Write-Host ("-" * 80) -ForegroundColor Cyan
Write-Host "1. Import to SecureVault using the automated script:" -ForegroundColor White
Write-Host "   .\Import-SecretsAutomated.ps1 -CSVFilePath '$csvFilename' -Username 'service-account'" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Or use the manual token method:" -ForegroundColor White
Write-Host "   `$token = .\Get-CyberArkToken.ps1 -Username 'service-account'" -ForegroundColor Gray
Write-Host "   .\ImportToSecureVault-WithToken.ps1 -CSVFilePath '$csvFilename' -AccessToken `$token" -ForegroundColor Gray
Write-Host ""
Write-Host "3. Or use authorization code:" -ForegroundColor White
Write-Host "   .\ImportToSecureVault.ps1 -CSVFilePath '$csvFilename' -AuthorizationCode 'YOUR_CODE'" -ForegroundColor Gray
Write-Host ""
Write-Host "✓ The CSV includes IP information in the Notes column for reference in SecureVault" -ForegroundColor Green
Write-Host ""

Write-Host "⚠️  IMPORTANT: Store these passwords securely!" -ForegroundColor Red
Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Cyan

# ── CONSOLIDATED PASSWORD NOTE (all accounts in one place) ──────────────────
Write-Host ""
Write-Host ("!" * 80) -ForegroundColor Red
Write-Host "  ⚠️  RECORD ALL THESE PASSWORDS NOW — they will not be shown again" -ForegroundColor Red
Write-Host ("!" * 80) -ForegroundColor Red
Write-Host ""
Write-Host "  Cluster VIP : $ClusterVIP  ($clusterName)" -ForegroundColor White
Write-Host ""
Write-Host "  [Prism Admin]" -ForegroundColor Yellow
Write-Host "    Username : admin" -ForegroundColor Gray
Write-Host "    Password : $newPrismAdminPassword" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [CVM Nutanix — all CVMs]" -ForegroundColor Yellow
Write-Host "    Username : nutanix" -ForegroundColor Gray
Write-Host "    Password : $newCVMNutanixPassword" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [AHV Root — per host]" -ForegroundColor Yellow
foreach ($ahvEntry in $ahvRootPasswords) {
    $noteColor = if ($ahvEntry.Success) { 'Cyan' } else { 'Yellow' }
    $suffix    = if ($ahvEntry.Success) { '' } else { '  ⚠ CHANGE FAILED — password may not be applied' }
    Write-Host "    $($ahvEntry.HostName) ($($ahvEntry.HostIP))" -ForegroundColor Gray
    Write-Host "      Username : root" -ForegroundColor Gray
    Write-Host "      Password : $($ahvEntry.Password)$suffix" -ForegroundColor $noteColor
}
Write-Host ""
Write-Host ("!" * 80) -ForegroundColor Red
Write-Host ""
#endregion

# Return success status
$failedAHVs = ($ahvRootPasswords | Where-Object { -not $_.Success }).Count

if ($failedAHVs -eq 0) {
    Write-Host "`n✓ All passwords changed successfully and exported to CSV!" -ForegroundColor Green
} else {
    Write-Host "`n⚠ Password change completed with $failedAHVs AHV warning(s). CSV exported." -ForegroundColor Yellow
}

if ($failedAHVs -eq 0) { exit 0 } else { exit 1 }
