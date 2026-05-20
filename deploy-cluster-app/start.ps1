#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    One-shot setup for Nutanix Cluster Deployment Manager.

.DESCRIPTION
    Run this once on a fresh Windows server (PowerShell as Administrator).
    It installs all dependencies, generates an SSL certificate, installs
    Posh-SSH, and registers + starts the application as a Windows service.

    Manual step-by-step instructions are in README.md.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot   # deploy-cluster-app/

function Write-Step { param([string]$msg) Write-Host "" ; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$msg) Write-Host "    OK  : $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "    WARN: $msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$msg) Write-Host "    ERR : $msg" -ForegroundColor Red }

# Step 1 - Node.js
Write-Step "Step 1 -- Checking Node.js"

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    Write-Host "    Node.js not found. Installing via winget..." -ForegroundColor Yellow
    winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements

    # Reload PATH from registry so 'node' is available in this session
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')

    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCmd) {
        Write-Err "Node.js installed but 'node' is still not on PATH."
        Write-Host "    Close this window, reopen PowerShell as Administrator, and re-run start.ps1." -ForegroundColor Yellow
        exit 1
    }
}
Write-OK "Node.js $((node --version))"

# Step 2 - PowerShell 7
Write-Step "Step 2 -- Checking PowerShell 7"
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshCmd) {
    Write-Host "    PowerShell 7 not found. Installing via winget..." -ForegroundColor Yellow
    winget install Microsoft.PowerShell --accept-source-agreements --accept-package-agreements
    # Reload PATH so pwsh is available in this session
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    Write-OK "PowerShell 7 installed (available as pwsh.exe)"
} else {
    Write-OK "PowerShell 7 already installed: $((pwsh --version))"
}

# Step 3 - npm install
Write-Step "Step 3 -- Installing npm packages"
Set-Location $scriptDir
npm install --prefer-offline
Write-OK "npm packages installed"

# Reset admin password to default (Changeme) using bcryptjs
$adminPwdJs = "const b=require('./node_modules/bcryptjs');const fs=require('fs');const d=JSON.parse(fs.readFileSync('users.json'));const a=d.users.find(function(u){return u.username==='admin';});if(a){a.password=b.hashSync('Changeme',10);fs.writeFileSync('users.json',JSON.stringify(d,null,2));console.log('Admin password reset to: Changeme');}else{console.log('WARN: admin user not found');}";
node -e $adminPwdJs

# Step 4 - .env file
Write-Step "Step 4 -- Configuring .env"
$envFile = Join-Path $scriptDir '.env'

if (-not (Test-Path $envFile)) {
    Write-Host "    .env not found - creating with generated defaults..." -ForegroundColor Yellow

    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RNGCryptoServiceProvider]::new().GetBytes($bytes)
    $secret = [Convert]::ToBase64String($bytes)

    $envContent  = "# =============================================================================`r`n"
    $envContent += "# Nutanix ZTI Deployment Manager - Environment Configuration`r`n"
    $envContent += "# =============================================================================`r`n"
    $envContent += "# Edit values below, then restart the service to apply changes.`r`n"
    $envContent += "# See .env.example for full documentation of every field.`r`n"
    $envContent += "# =============================================================================`r`n"
    $envContent += "`r`n"
    $envContent += "# --- Company Branding -------------------------------------------------------`r`n"
    $envContent += "# Shown in browser tab, nav bar, and login page (no restart needed).`r`n"
    $envContent += "COMPANY_NAME=Your Company Name`r`n"
    $envContent += "`r`n"
    $envContent += "# --- Web Server -------------------------------------------------------------`r`n"
    $envContent += "PORT=3443`r`n"
    $envContent += "# Public URL used in welcome emails - auto-set to this machine's hostname.`r`n"
    $envContent += "SERVER_URL=https://$($env:COMPUTERNAME):3443`r`n"
    $envContent += "`r`n"
    $envContent += "# --- Security ---------------------------------------------------------------`r`n"
    $envContent += "# Auto-generated random secret - do not share or commit this value.`r`n"
    $envContent += "SESSION_SECRET=$secret`r`n"
    $envContent += "`r`n"
    $envContent += "# --- SMTP / Email -------------------------------------------------------`r`n"
    $envContent += "# Pipeline result emails (Send-PipelineEmail.ps1) read SMTP settings from here.`r`n"
    $envContent += "# Web app welcome emails use Admin > SMTP Settings in the UI.`r`n"
    $envContent += "# Set SMTP_HOST to your real relay, or leave blank to skip pipeline emails.`r`n"
    $envContent += "SMTP_HOST=`r`n"
    $envContent += "# Port: 25=relay, 587=STARTTLS, 465=SMTPS`r`n"
    $envContent += "SMTP_PORT=25`r`n"
    $envContent += "# Sender address shown in the From header of outgoing emails`r`n"
    $envContent += "SMTP_USER=noreply@company.com`r`n"
    $envContent += "`r`n"
    $envContent += "# --- Development (optional) -------------------------------------------------`r`n"
    $envContent += "# Uncomment to enable full stack traces in API error responses.`r`n"
    $envContent += "# NODE_ENV=production`r`n"
    [System.IO.File]::WriteAllText($envFile, $envContent, [System.Text.Encoding]::UTF8)

    Write-OK ".env created with auto-generated session secret and server URL"
    Write-Warn "Edit COMPANY_NAME in .env before going live (and any SMTP settings)"
} else {
    Write-OK ".env already exists - skipping"
}

# Step 5 - SSL Certificate
Write-Step "Step 5 -- Generating SSL certificate"
$certKey = Join-Path $scriptDir 'certs\server.key'
$certCrt = Join-Path $scriptDir 'certs\server.crt'

if ((Test-Path $certKey) -and (Test-Path $certCrt)) {
    Write-OK "Certificates already exist - skipping (delete certs\ to regenerate)"
} else {
    & (Join-Path $scriptDir 'generate-cert.ps1')
    Write-OK "SSL certificate generated"
}

# Step 6 - Posh-SSH
Write-Step "Step 6 -- Installing Posh-SSH PowerShell module"
if (Get-Module -ListAvailable -Name Posh-SSH -ErrorAction SilentlyContinue) {
    Write-OK "Posh-SSH already installed"
} else {
    Install-Module -Name Posh-SSH -Force -Scope AllUsers
    Write-OK "Posh-SSH installed"
}

# Step 7 - Windows Service
Write-Step "Step 7 -- Installing Windows service"
Set-Location $scriptDir
node install-service.js

Write-Host "    Starting service..." -ForegroundColor Yellow
try {
    Start-Service 'Nutanix Cluster Deployment Web' -ErrorAction Stop
    $svc = Get-Service 'Nutanix Cluster Deployment Web'
    Write-OK "Service status: $($svc.Status)"
} catch {
    Write-Warn "Could not start service: $_"
    Write-Host "    If the service was previously installed in a broken state, run:" -ForegroundColor Yellow
    Write-Host "      node uninstall-service.js" -ForegroundColor Yellow
    Write-Host "      node install-service.js" -ForegroundColor Yellow
    Write-Host "      Start-Service 'Nutanix Cluster Deployment Web'" -ForegroundColor Yellow
}

# Done
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "  Portal URL : https://$($env:COMPUTERNAME):3443" -ForegroundColor Green
Write-Host "  Username   : admin" -ForegroundColor Green
Write-Host "  Password   : Changeme  (change after first login!)" -ForegroundColor Green
Write-Host "  Branding   : edit .env to change COMPANY_NAME" -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green