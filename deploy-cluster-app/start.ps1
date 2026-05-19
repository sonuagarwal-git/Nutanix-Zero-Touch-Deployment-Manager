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

function Write-Step { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$msg) Write-Host "    OK  : $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "    WARN: $msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$msg) Write-Host "    ERR : $msg" -ForegroundColor Red }

# ── Step 1 — Node.js ──────────────────────────────────────────────────────────
Write-Step "Step 1 — Checking Node.js"

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

# ── Step 2 — npm install ──────────────────────────────────────────────────────
Write-Step "Step 2 — Installing npm packages"
Set-Location $scriptDir
npm install --prefer-offline
Write-OK "npm packages installed"

# ── Step 3 — .env file ────────────────────────────────────────────────────────
Write-Step "Step 3 — Configuring .env"
$envFile = Join-Path $scriptDir '.env'

if (-not (Test-Path $envFile)) {
    Write-Host "    .env not found — creating with generated defaults..." -ForegroundColor Yellow

    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RNGCryptoServiceProvider]::new().GetBytes($bytes)
    $secret = [Convert]::ToBase64String($bytes)

    @"
# Nutanix ZTI Deployment Tool - Environment Configuration
# --- Company Branding ---
COMPANY_NAME=Your Company Name
# --- Security ---
SESSION_SECRET=$secret
# --- SMTP / Email ---
SMTP_HOST=smtp.example.com
SMTP_PORT=25
SMTP_USER=noreply@company.com
# --- Server URL ---
SERVER_URL=https://$($env:COMPUTERNAME):3443
"@ | Set-Content $envFile -Encoding UTF8

    Write-OK ".env created with a generated session secret"
    Write-Warn "Edit .env to set COMPANY_NAME (and other values) before going live"
} else {
    Write-OK ".env already exists — skipping"
}

# ── Step 4 — SSL Certificate ──────────────────────────────────────────────────
Write-Step "Step 4 — Generating SSL certificate"
$certKey = Join-Path $scriptDir 'certs\server.key'
$certCrt = Join-Path $scriptDir 'certs\server.crt'

if ((Test-Path $certKey) -and (Test-Path $certCrt)) {
    Write-OK "Certificates already exist — skipping (delete certs\ to regenerate)"
} else {
    & (Join-Path $scriptDir 'generate-cert.ps1')
    Write-OK "SSL certificate generated"
}

# ── Step 5 — Posh-SSH ────────────────────────────────────────────────────────
Write-Step "Step 5 — Installing Posh-SSH PowerShell module"
if (Get-Module -ListAvailable -Name Posh-SSH -ErrorAction SilentlyContinue) {
    Write-OK "Posh-SSH already installed"
} else {
    Install-Module -Name Posh-SSH -Force -Scope AllUsers
    Write-OK "Posh-SSH installed"
}

# ── Step 6 — Windows Service ──────────────────────────────────────────────────
Write-Step "Step 6 — Installing Windows service"
Set-Location $scriptDir
node install-service.js

Write-Host "    Starting service..." -ForegroundColor Yellow
try {
    Start-Service 'Nutanix Cluster Deployment Web' -ErrorAction Stop
    $svc = Get-Service 'Nutanix Cluster Deployment Web'
    Write-OK "Service status: $($svc.Status)"
} catch {
    Write-Warn "Could not start service: $_"
    Write-Host "    If the service was already registered from a previous failed install, run:" -ForegroundColor Yellow
    Write-Host "      node uninstall-service.js" -ForegroundColor Yellow
    Write-Host "      node install-service.js" -ForegroundColor Yellow
    Write-Host "      Start-Service 'Nutanix Cluster Deployment Web'" -ForegroundColor Yellow
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "  Portal URL : https://$($env:COMPUTERNAME):3443" -ForegroundColor Green
Write-Host "  Login      : admin  (set password in users.json)" -ForegroundColor Green
Write-Host "  Branding   : edit .env to change COMPANY_NAME" -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
