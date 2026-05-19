#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Tear-down script for Nutanix Cluster Deployment Manager.

.DESCRIPTION
    Reverses everything start.ps1 did so you can run a clean end-to-end test again.
    Stops and uninstalls the service, removes packages, uninstalls Node.js and
    Posh-SSH, and deletes generated files (.env, certs\, node_modules\).
#>

$ErrorActionPreference = 'Continue'

$scriptDir = $PSScriptRoot   # deploy-cluster-app/

function Write-Step { param([string]$msg) Write-Host "" ; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$msg) Write-Host "    OK  : $msg" -ForegroundColor Green }
function Write-Skip { param([string]$msg) Write-Host "    SKIP: $msg" -ForegroundColor Gray }
function Write-Warn { param([string]$msg) Write-Host "    WARN: $msg" -ForegroundColor Yellow }

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

# Step 3 - Uninstall Posh-SSH
Write-Step "Step 3 -- Uninstalling Posh-SSH"
if (Get-Module -ListAvailable -Name Posh-SSH -ErrorAction SilentlyContinue) {
    Uninstall-Module -Name Posh-SSH -AllVersions -Force -ErrorAction SilentlyContinue
    Write-OK "Posh-SSH uninstalled"
} else {
    Write-Skip "Posh-SSH not installed"
}

# Step 4 - Uninstall Node.js
Write-Step "Step 4 -- Uninstalling Node.js"
$nodeCheck = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCheck) {
    winget uninstall OpenJS.NodeJS.LTS --accept-source-agreements
    Write-OK "Node.js uninstalled"
} else {
    Write-Skip "Node.js not installed"
}

# Step 5 - Uninstall PowerShell 7
Write-Step "Step 5 -- Uninstalling PowerShell 7"
$pwshCheck = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCheck) {
    winget uninstall Microsoft.PowerShell --accept-source-agreements
    Write-OK "PowerShell 7 uninstalled"
} else {
    Write-Skip "PowerShell 7 not installed"
}

# Step 6 - Delete .env
Write-Step "Step 6 -- Deleting .env"
$envFile = Join-Path $scriptDir '.env'
if (Test-Path $envFile) {
    Remove-Item $envFile -Force
    Write-OK ".env deleted"
} else {
    Write-Skip ".env not found"
}

# Step 7 - Delete SSL certificates
Write-Step "Step 7 -- Deleting SSL certificates"
$certsDir = Join-Path $scriptDir 'certs'
if (Test-Path $certsDir) {
    Remove-Item $certsDir -Recurse -Force
    Write-OK "certs\ deleted"
} else {
    Write-Skip "certs\ not found"
}

# Done
Write-Host ""
Write-Host "======================================================" -ForegroundColor Magenta
Write-Host "  Cleanup complete!" -ForegroundColor Magenta
Write-Host "  Run .\start.ps1 to set up from scratch again." -ForegroundColor Magenta
Write-Host "======================================================" -ForegroundColor Magenta