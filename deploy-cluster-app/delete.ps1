#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Tear-down script for Nutanix Zero Touch Deployment Manager.

.DESCRIPTION
    Reverses everything start.ps1 did so you can run a clean end-to-end test again.
    Stops and uninstalls the service, removes packages, uninstalls Node.js and
    optionally uninstalls Posh-SSH and PowerShell 7, deletes generated files
    (.env, certs\, node_modules\), and resets all deployment history and log files
    to an empty state.
#>

$ErrorActionPreference = 'Continue'

$scriptDir = $PSScriptRoot   # deploy-cluster-app/

function Write-Step { param([string]$msg) Write-Host "" ; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$msg) Write-Host "    OK  : $msg" -ForegroundColor Green }
function Write-Skip { param([string]$msg) Write-Host "    SKIP: $msg" -ForegroundColor Gray }
function Write-Warn { param([string]$msg) Write-Host "    WARN: $msg" -ForegroundColor Yellow }

function Confirm-YesNo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $answer = Read-Host "$Message [Y/N]"

    return ($answer -match '^(Y|y)$')
}

# Step 1 - Stop and uninstall Windows service
Write-Step "Step 1 -- Stopping and uninstalling Windows service"
$svc = Get-Service 'Nutanix Cluster Deployment Web' -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -eq 'Running') {
        Stop-Service 'Nutanix Cluster Deployment Web' -Force -ErrorAction SilentlyContinue
        Write-OK "Service stopped"
    }

    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) {
        Set-Location $scriptDir
        node uninstall-service.js
    } else {
        Write-Warn "node not found - removing service via sc.exe"
        sc.exe delete $svc.Name | Out-Null
        Write-OK "Service removed via sc.exe (name: $($svc.Name))"
    }
} else {
    Write-Skip "Service not installed"
}

# Clean up daemon WinSW exe so next install-service.js starts fresh
$daemonExe = Join-Path $scriptDir 'daemon\nutanixclusterdeploymentweb.exe'
if (Test-Path $daemonExe) {
    Remove-Item $daemonExe -Force -ErrorAction SilentlyContinue
    Write-OK "Removed daemon\nutanixclusterdeploymentweb.exe"
}

# Step 2 - Delete node_modules
Write-Step "Step 2 -- Deleting node_modules"
$nmPath = Join-Path $scriptDir 'node_modules'
if (Test-Path $nmPath) {
    Write-Host "    Removing node_modules (may take a moment)..." -ForegroundColor Yellow
    Remove-Item $nmPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-OK "node_modules deleted"
} else {
    Write-Skip "node_modules not found"
}

# Step 3 - Uninstall Node.js
Write-Step "Step 3 -- Uninstalling Node.js"
$nodeCheck = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCheck) {
    winget uninstall OpenJS.NodeJS.LTS --accept-source-agreements
    Write-OK "Node.js uninstalled"
} else {
    Write-Skip "Node.js not installed"
}

# Step 4 - Delete .env
Write-Step "Step 4 -- Deleting .env"
$envFile = Join-Path $scriptDir '.env'
if (Test-Path $envFile) {
    Remove-Item $envFile -Force
    Write-OK ".env deleted"
} else {
    Write-Skip ".env not found"
}

# Step 5 - Delete SSL certificates
Write-Step "Step 5 -- Deleting SSL certificates"
$certsDir = Join-Path $scriptDir 'certs'
if (Test-Path $certsDir) {
    Remove-Item $certsDir -Recurse -Force
    Write-OK "certs\ deleted"
} else {
    Write-Skip "certs\ not found"
}

# Step 6 - Reset deployment data and log files
Write-Step "Step 6 -- Resetting deployment data and logs"
$dataFiles = @(
    @{ Path = Join-Path $scriptDir 'deployments.json';    Empty = '{ "deployments": [] }' }
    @{ Path = Join-Path $scriptDir 'audit-logs.json';     Empty = '{ "logs": [] }' }
    @{ Path = Join-Path $scriptDir 'last-deployment.json'; Empty = '{}' }
    @{ Path = Join-Path (Split-Path $scriptDir -Parent) 'Nutanix-ZTI\historical-timings.json'; Empty = '{ "deployments": [] }' }
)
foreach ($f in $dataFiles) {
    if (Test-Path $f.Path) {
        [System.IO.File]::WriteAllText($f.Path, $f.Empty, [System.Text.Encoding]::UTF8)
        Write-OK "Reset: $(Split-Path $f.Path -Leaf)"
    } else {
        Write-Skip "Not found: $($f.Path)"
    }
}

# Step 7 - Uninstall Posh-SSH
Write-Step "Step 7 -- Uninstalling Posh-SSH"
if (Get-Module -ListAvailable -Name Posh-SSH -ErrorAction SilentlyContinue) {
    if (Confirm-YesNo "Do you want to uninstall Posh-SSH?") {
        Uninstall-Module -Name Posh-SSH -AllVersions -Force -ErrorAction SilentlyContinue
        Write-OK "Posh-SSH uninstalled"
    } else {
        Write-Skip "User chose not to uninstall Posh-SSH"
    }
} else {
    Write-Skip "Posh-SSH not installed"
}

# Step 8 - Uninstall PowerShell 7
Write-Step "Step 8 -- Uninstalling PowerShell 7"
$pwshCheck = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCheck) {
    if (Confirm-YesNo "Do you want to uninstall PowerShell 7?") {
        # --all-versions handles the case where both an MSI machine-wide and an
        # MSIX/winget per-user install exist simultaneously — winget errors if it
        # finds multiple versions without an explicit selector.
        winget uninstall Microsoft.PowerShell --all-versions --accept-source-agreements
        Write-OK "PowerShell 7 uninstalled"
    } else {
        Write-Skip "User chose not to uninstall PowerShell 7"
    }
} else {
    Write-Skip "PowerShell 7 not installed"
}

# Done
Write-Host ""
Write-Host "======================================================" -ForegroundColor Magenta
Write-Host "  Delete complete!" -ForegroundColor Magenta
Write-Host "  Run .\start.ps1 to set up from scratch again." -ForegroundColor Magenta
Write-Host "======================================================" -ForegroundColor Magenta