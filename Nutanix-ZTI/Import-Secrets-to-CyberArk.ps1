<#
.SYNOPSIS
    Automated secret import - Self-contained script with built-in token generation

.DESCRIPTION
    This self-contained script automates the full workflow:
    1. Obtains a fresh access token from CyberArk Identity (built-in)
    2. Immediately imports secrets from CSV file (built-in)
    
    No external script dependencies - everything is in one file.

.PARAMETER CSVFilePath
    Path to the CSV file containing secrets to import
    CSV format (space-delimited):
      Name Server_Name Username Password Tags Folder Notes
    
    Fields:
      - Name: Display name of the secret (required)
      - Server_Name: Server hostname/IP (optional, stored in Description)
      - Username: Account username (required)
      - Password: Account password (required)
      - Tags: Semicolon-separated tags (optional, e.g., "Tag1;Tag2")
      - Folder: Folder name to organize secrets (optional, auto-created if doesn't exist)
      - Notes: Additional notes (optional, e.g., IP addresses, connection details)
    
    Example CSV:
    Name Server_Name Username Password Tags Folder Notes
    Prism_Admin prism01 admin Pass123 Nutanix Nutanix-test Prism_Element_Cluster_VIP:10.1.1.10
    CVM_Nutanix cvm01 nutanix Pass456 Nutanix Nutanix-test CVM_IPs:10.1.1.11,10.1.1.12
    AHV_Root ahv01 root Pass789 Nutanix Nutanix-test AHV_Host_IP:10.1.1.13

.PARAMETER Username
    CyberArk Identity service account username

.PARAMETER Password
    (Optional) Service account password. If not provided, will prompt.

.PARAMETER SecurityAnswer
    (Optional) Security question answer. If not provided, will prompt.

.PARAMETER TenantId
    CyberArk Identity Tenant ID (default: aap4624)

.PARAMETER BaseURL
    CyberArk Identity base URL (default: https://aap4624.id.cyberark.cloud)

.EXAMPLE
    # Interactive mode (will prompt for password and security answer)
    .\Import-SecretsAutomated.ps1 `
        -CSVFilePath ".\DKCDC-1P-NTXTEST-01_Password.csv" `
        -Username "core-service-securevault-monitoring@vestas.com.65"

.EXAMPLE
    # Fully automated mode (for scheduled tasks)
    $secPass = ConvertTo-SecureString "YourPassword" -AsPlainText -Force
    $secAnswer = ConvertTo-SecureString "YourAnswer" -AsPlainText -Force
    .\Import-SecretsAutomated.ps1 `
        -CSVFilePath ".\secrets.csv" `
        -Username "svc@vestas.com" `
        -Password $secPass `
        -SecurityAnswer $secAnswer

.NOTES
    Author  : DCES Core Service Team
    Date    : March 23, 2026
    Version : 2.0 (Self-contained - no external dependencies)
    
    Benefits:
    - Completely self-contained - no external script dependencies
    - Eliminates manual token copy/paste errors
    - Prevents token expiration between steps
    - Streamlines the import workflow
    
    CSV Format (space-delimited):
    Name Server_Name Username Password Tags Folder Notes
    
    Example with Notes:
    Prism_Admin DKCDC-1P-NTXTEST-01 admin Pass123 Nutanix Nutanix-test Prism_Element_Cluster_VIP:10.1.1.10
    CVM_Nutanix cvm01 nutanix Pass456 Nutanix Nutanix-test CVM_IPs:10.1.1.11,10.1.1.12
    AHV_Root ahv01 root Pass789 Nutanix Nutanix-test AHV_Host_IP:10.1.1.13
    
    Notes Field Usage:
    - Prism_Admin: Prism Element IP (Cluster VIP)
    - CVM_Nutanix: Both CVM IP addresses (comma-separated)
    - AHV_Root: Individual AHV host IP address
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Path to the deployment JSON config file")]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false, HelpMessage = "Path to the CSV file containing secrets")]
    [string]$CSVFilePath,

    [Parameter(Mandatory = $false, HelpMessage = "CyberArk service account username")]
    [ValidateNotNullOrEmpty()]
    [string]$Username = "core-service-securevault-monitoring@vestas.com.65",

    [Parameter(Mandatory = $false, HelpMessage = "Service account password (prompts if not provided)")]
    [SecureString]$Password,

    [Parameter(Mandatory = $false, HelpMessage = "Security question answer (prompts if not provided)")]
    [SecureString]$SecurityAnswer,

    [Parameter(Mandatory = $false)]
    [string]$TenantId = "aap4624",

    [Parameter(Mandatory = $false)]
    [string]$BaseURL = "https://aap4624.id.cyberark.cloud"
)

# ── Resolve credentials from config file if provided ───────────────────────
if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $ck  = $cfg.cyberark
    if ($ck) {
        if ($ck.username)        { $Username  = $ck.username }
        if ($ck.tenant_id)       { $TenantId  = $ck.tenant_id }
        if ($ck.base_url)        { $BaseURL   = $ck.base_url }
        if ($ck.password         -and -not $Password) {
            $Password       = ConvertTo-SecureString $ck.password        -AsPlainText -Force
        }
        if ($ck.security_answer  -and -not $SecurityAnswer) {
            $SecurityAnswer = ConvertTo-SecureString $ck.security_answer -AsPlainText -Force
        }
    }
    # Derive CSV filename from cluster name if not explicitly provided
    if (-not $CSVFilePath -and $cfg.clusterName) {
        $csvDir  = $PSScriptRoot
        $CSVFilePath = Join-Path $csvDir "$($cfg.clusterName)_Password.csv"
    }
}

if (-not $CSVFilePath) {
    Write-Host "ERROR: CSVFilePath must be provided via -ConfigFile or -CSVFilePath." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $CSVFilePath -PathType Leaf)) {
    Write-Host "ERROR: CSV file not found: $CSVFilePath" -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Web

# ═════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═════════════════════════════════════════════════════════════════════════════

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "Info"    { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function ConvertFrom-SecureStringToPlainText {
    param([SecureString]$SecureString)
    
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function New-SymmetricKey {
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] 32
    $random.GetBytes($buffer)
    return [BitConverter]::ToString($buffer).Replace("-", [string]::Empty)
}

function Get-CyberArkAccessToken {
    param(
        [string]$Username,
        [string]$PasswordPlain,
        [string]$SecurityAnswerPlain,
        [string]$TenantId,
        [string]$BaseURL
    )
    
    Write-Log "Starting authentication session..." "Info"
    
    # Step 1: Start Authentication
    $startAuthBody = @{
        TenantId = $TenantId
        Version = "1.0"
        User = $Username
    } | ConvertTo-Json
    
    $startAuthResponse = Invoke-WebRequest `
        -Uri "$BaseURL/Security/StartAuthentication" `
        -Method Post `
        -ContentType "application/json" `
        -Body $startAuthBody `
        -UseBasicParsing `
        -ErrorAction Stop
    
    $startAuthContent = $startAuthResponse.Content | ConvertFrom-Json
    
    if ($startAuthContent.success -eq $false) {
        throw "StartAuthentication failed: $($startAuthContent.Message)"
    }
    
    $sessionId = $startAuthContent.Result.SessionId
    $upMechanismId = $startAuthContent.Result.Challenges[0].Mechanisms[0].MechanismId
    $sqMechanismId = $startAuthContent.Result.Challenges[1].Mechanisms[0].MechanismId
    
    Write-Log "Authentication session started successfully." "Success"
    
    # Step 2: Answer Password Challenge
    Write-Log "Answering password challenge..." "Info"
    
    $passwordChallengeBody = @{
        Action = "Answer"
        Answer = $PasswordPlain
        SessionId = $sessionId
        MechanismId = $upMechanismId
    } | ConvertTo-Json
    
    $passwordChallengeResponse = Invoke-WebRequest `
        -Uri "$BaseURL/Security/AdvanceAuthentication" `
        -Method Post `
        -ContentType "application/json" `
        -Body $passwordChallengeBody `
        -UseBasicParsing `
        -ErrorAction Stop
    
    $passwordChallengeContent = $passwordChallengeResponse.Content | ConvertFrom-Json
    
    if ($passwordChallengeContent.success -eq $false) {
        throw "Password challenge failed: $($passwordChallengeContent.Message)"
    }
    
    Write-Log "Password challenge completed successfully." "Success"
    
    # Step 3: Answer Security Question Challenge
    Write-Log "Answering security question challenge..." "Info"
    
    $securityQuestionBody = @{
        Action = "Answer"
        Answer = $SecurityAnswerPlain
        SessionId = $sessionId
        MechanismId = $sqMechanismId
    } | ConvertTo-Json
    
    $securityQuestionResponse = Invoke-WebRequest `
        -Uri "$BaseURL/Security/AdvanceAuthentication" `
        -Method Post `
        -ContentType "application/json" `
        -Body $securityQuestionBody `
        -UseBasicParsing `
        -ErrorAction Stop
    
    $securityQuestionContent = $securityQuestionResponse.Content | ConvertFrom-Json
    
    if ($securityQuestionContent.success -eq $false) {
        throw "Security question challenge failed: $($securityQuestionContent.Message)"
    }
    
    $accessToken = $securityQuestionContent.Result.Token
    Write-Log "Authentication completed successfully." "Success"
    
    return $accessToken
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN SCRIPT
# ═════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "  CyberArk Identity - Automated Secret Import" -ForegroundColor Cyan
Write-Host "  CSV File : $CSVFilePath" -ForegroundColor Cyan
Write-Host "  Username : $Username" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""

try {
    # ─────────────────────────────────────────────────────────────────────────
    # Step 1: Get fresh access token (built-in logic)
    # ─────────────────────────────────────────────────────────────────────────
    Write-Host "▶ Step 1: Obtaining fresh access token..." -ForegroundColor Yellow
    Write-Host ""
    
    # Prompt for password if not provided
    if (-not $Password) {
        $Password = Read-Host "Enter password for $Username" -AsSecureString
    }
    
    # Prompt for security answer if not provided
    if (-not $SecurityAnswer) {
        $SecurityAnswer = Read-Host "Enter security question answer" -AsSecureString
    }
    
    # Convert secure strings to plain text for API calls
    $passwordPlain = ConvertFrom-SecureStringToPlainText -SecureString $Password
    $securityAnswerPlain = ConvertFrom-SecureStringToPlainText -SecureString $SecurityAnswer
    
    # Get the access token
    $accessToken = Get-CyberArkAccessToken `
        -Username $Username `
        -PasswordPlain $passwordPlain `
        -SecurityAnswerPlain $securityAnswerPlain `
        -TenantId $TenantId `
        -BaseURL $BaseURL
    
    # Clear sensitive data from memory
    $passwordPlain = $null
    $securityAnswerPlain = $null
    
    if (-not $accessToken) {
        throw "Failed to obtain access token"
    }
    
    Write-Host ""
    Write-Host "✓ Access token obtained successfully" -ForegroundColor Green
    Write-Host ""
    
    # ─────────────────────────────────────────────────────────────────────────
    # Step 2: Import secrets (built-in logic)
    # ─────────────────────────────────────────────────────────────────────────
    Write-Host "▶ Step 2: Importing secrets from CSV..." -ForegroundColor Yellow
    Write-Host ""
    
    # Read CSV file
    Write-Host "Reading CSV file: $CSVFilePath" -ForegroundColor Green
    $ImportedCSV = Import-Csv -LiteralPath $CSVFilePath -Delimiter ' '
    Write-Host "CSV file loaded successfully." -ForegroundColor Green

    # Get record count
    $counter = 1
    $itemCount = 1
    if ($ImportedCSV.Count) { $itemCount = $ImportedCSV.Count }
    Write-Host "Found $itemCount record(s) to import." -ForegroundColor Yellow
    Write-Host ""

    Write-Host "Starting import process..." -ForegroundColor Yellow
    Write-Host ""
    
    # Get list of all unique folders from CSV
    $uniqueFolders = $ImportedCSV | Where-Object { $_.Folder -and $_.Folder -ne "" } | Select-Object -ExpandProperty Folder -Unique
    
    # Folder UUID cache to avoid repeated API calls
    $folderCache = @{}
    
    if ($uniqueFolders) {
        Write-Host "Processing folders..." -ForegroundColor Cyan
        
        # Get all existing folders from CyberArk
        try {
            $resultFolders = Invoke-WebRequest `
                -Uri "$BaseURL/Folder/GetFolders" `
                -Method Post `
                -ContentType "application/json" `
                -Headers @{ Authorization = "Bearer $accessToken" } `
                -UseBasicParsing
            $SecureVaultFolders = ($resultFolders.Content | ConvertFrom-Json).Result
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 401) {
                throw "Authentication failed (401). Token may have expired or is invalid."
            }
            throw "Failed to retrieve folders: $($_.Exception.Message)"
        }
        
        foreach ($folderName in $uniqueFolders) {
            $folderUuid = ($SecureVaultFolders | Where-Object { $_.Name -ieq $folderName.Trim() }).FolderUuid
            
            if (!$folderUuid) {
                Write-Host "Creating folder: $folderName" -ForegroundColor Yellow
                $bodyFolder = @{
                    Name = $folderName.Trim()
                } | ConvertTo-Json
                $resultFolder = Invoke-WebRequest `
                    -Uri "$BaseURL/Folder/SaveFolder" `
                    -Method Post `
                    -ContentType "application/json" `
                    -Body $bodyFolder `
                    -Headers @{ Authorization = "Bearer $accessToken" } `
                    -UseBasicParsing
                $folderUuid = ($resultFolder.Content | ConvertFrom-Json).Result
                Write-Host "  ✓ Folder '$folderName' created (UUID: $folderUuid)" -ForegroundColor Green
            } else {
                Write-Host "  ✓ Folder '$folderName' already exists (UUID: $folderUuid)" -ForegroundColor Green
            }
            
            $folderCache[$folderName] = $folderUuid
        }
        Write-Host ""
    }

    # Get existing secrets — store name → ItemKey map for credential reads and updates
    Write-Host "Checking for existing secrets..." -ForegroundColor Cyan
    $existingSecretsMap = @{}   # name → ItemKey
    try {
        $resultSecrets = Invoke-WebRequest `
            -Uri "$BaseURL/UPRest/GetSecuredItemsData" `
            -Method Post `
            -ContentType "application/json" `
            -Headers @{ Authorization = "Bearer $accessToken" } `
            -UseBasicParsing
        $allSecrets = ($resultSecrets.Content | ConvertFrom-Json).Result.SecuredItems
        foreach ($s in $allSecrets) { $existingSecretsMap[$s.Name] = $s.ItemKey }
        Write-Host "Found $($existingSecretsMap.Count) existing secret(s)." -ForegroundColor Green
    } catch {
        Write-Host "  ⚠ Could not retrieve existing secrets. Will attempt add for all items." -ForegroundColor Yellow
    }
    Write-Host ""

    # ── Helper: build and add a brand-new secret ─────────────────────────────
    function Add-SecretItem {
        param($item, $label, $accessToken, $BaseURL, $folderCache)
        $tempBody = @{
            SecuredItemType = "Password"
            Name            = $item.name
            Username        = $item.Username
            Password        = $item.Password
            SymmetricKey    = New-SymmetricKey
            Notes           = if ($item.Notes)       { $item.Notes }       else { "" }
            Description     = if ($item.Server_Name) { "Server Name: $($item.Server_Name)" } else { "" }
        }
        $tagValue = if ($item.Tags) { $item.Tags } elseif ($item.tags) { $item.tags } else { $null }
        if ($tagValue -and $tagValue -ne "") {
            $tempBody.Add("tagnames", $tagValue.Split(";"))
        }
        $result  = Invoke-WebRequest `
            -Uri "$BaseURL/UPRest/AddSecuredItem" `
            -Method Post `
            -ContentType "application/json" `
            -Body ($tempBody | ConvertTo-Json) `
            -Headers @{ Authorization = "Bearer $accessToken" } `
            -UseBasicParsing
        $content = $result.Content | ConvertFrom-Json
        if ($content.success -eq $false) {
            Write-Host "$label | ADD FAILED | $($content.Message)" -ForegroundColor Red
            return $false
        }
        Write-Host "$label | Status: $($result.StatusCode) | Added" -ForegroundColor Green
        # Move to folder
        if ($item.Folder -and $item.Folder -ne "" -and $folderCache.ContainsKey($item.Folder)) {
            $moveBody    = @{ _RowKey = $content.Result; ActionType = "Add"; Type = "SecuredItem"; FolderUuid = $folderCache[$item.Folder] } | ConvertTo-Json
            $resultMove  = Invoke-WebRequest `
                -Uri "$BaseURL/Folder/SetFolder" `
                -Method Post `
                -ContentType "application/json" `
                -Body $moveBody `
                -Headers @{ Authorization = "Bearer $accessToken" } `
                -UseBasicParsing
            $moveContent = $resultMove.Content | ConvertFrom-Json
            if ($moveContent.success -eq $false) {
                Write-Host "  ⚠ Failed to move to folder '$($item.Folder)': $($moveContent.Message)" -ForegroundColor Yellow
            } else {
                Write-Host "  ✓ Moved to folder: $($item.Folder)" -ForegroundColor Cyan
            }
        }
        return $true
    }

    Write-Host "Starting secret upload..." -ForegroundColor Cyan
    Write-Host ""

    $failedCount = 0

    foreach ($item in $ImportedCSV) {
        Write-Progress `
            -Activity "Uploading to CyberArk Identity User Portal." `
            -Status "[$counter/$itemCount] $($item.name)" `
            -PercentComplete (($counter / $itemCount) * 100)

        $label = "[$counter/$itemCount] $($item.name)"

        if ($existingSecretsMap.ContainsKey($item.name)) {
            # ── Secret exists: read current password and compare ──────────────
            $itemKey   = $existingSecretsMap[$item.name]
            $currentPw = $null
            try {
                $getResult  = Invoke-WebRequest `
                    -Uri "$BaseURL/UPRest/GetCredsForSecuredItem?sItemKey=$itemKey" `
                    -Method Get `
                    -Headers @{ Authorization = "Bearer $accessToken" } `
                    -UseBasicParsing
                $getContent = $getResult.Content | ConvertFrom-Json
                $currentPw  = $getContent.Result.p   # 'p' = password field per API spec
            } catch {
                Write-Host "$label | READ ERROR | $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "  ↳ Cannot compare passwords — treating as update needed." -ForegroundColor Yellow
            }

            if ($null -ne $currentPw -and $currentPw -eq $item.Password) {
                Write-Host "$label | OK | Already up to date (password matches, no update needed)" -ForegroundColor Green
            } else {
                # Passwords differ (or read failed) — call the official update endpoint
                $updateBody = @{
                    Password = $item.Password
                    Username = $item.Username
                    Notes    = if ($item.Notes) { $item.Notes } else { "" }
                } | ConvertTo-Json
                try {
                    $updResult  = Invoke-WebRequest `
                        -Uri "$BaseURL/UPRest/UpdateCredsForSecuredItem?sItemKey=$itemKey" `
                        -Method Post `
                        -ContentType "application/json" `
                        -Body $updateBody `
                        -Headers @{ Authorization = "Bearer $accessToken" } `
                        -UseBasicParsing
                    $updContent = $updResult.Content | ConvertFrom-Json
                    if ($updContent.success -eq $false) {
                        Write-Host "$label | UPDATE FAILED | $($updContent.Message)" -ForegroundColor Red
                        $failedCount++
                    } else {
                        Write-Host "$label | UPDATED | Password overwritten" -ForegroundColor Cyan
                    }
                } catch {
                    Write-Host "$label | UPDATE ERROR | $($_.Exception.Message)" -ForegroundColor Red
                    $failedCount++
                }
            }
        } else {
            # New secret — add directly
            $ok = Add-SecretItem -item $item -label $label -accessToken $accessToken -BaseURL $BaseURL -folderCache $folderCache
            if (-not $ok) { $failedCount++ }
        }

        $counter++
    }

    Write-Progress -Activity "Uploading to CyberArk Identity User Portal." -Completed

    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor $(if ($failedCount -eq 0) { 'Green' } else { 'Red' })
    Write-Host "  Import Complete!" -ForegroundColor $(if ($failedCount -eq 0) { 'Green' } else { 'Red' })
    Write-Host ("=" * 80) -ForegroundColor $(if ($failedCount -eq 0) { 'Green' } else { 'Red' })
    Write-Host "  Total Records Processed : $itemCount" -ForegroundColor Cyan
    Write-Host "  Succeeded               : $($itemCount - $failedCount)" -ForegroundColor $(if ($failedCount -eq 0) { 'Green' } else { 'Yellow' })
    if ($failedCount -gt 0) {
        Write-Host "  Failed                  : $failedCount  ← passwords NOT updated in CyberArk!" -ForegroundColor Red
    }
    Write-Host ("=" * 80) -ForegroundColor $(if ($failedCount -eq 0) { 'Green' } else { 'Red' })
    Write-Host ""

    if ($failedCount -gt 0) { exit 1 } else { exit 0 }
    
} catch {
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Red
    Write-Host "  ERROR: Import Failed" -ForegroundColor Red
    Write-Host ("=" * 80) -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    exit 1
}
