#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Agent Fleet — Windows Installer
    Installs WSL2, Ubuntu, Node.js, Claude Code, and agent-fleet in one step.

.DESCRIPTION
    For users who don't have WSL or git set up. Run this in an elevated PowerShell:
        irm https://raw.githubusercontent.com/JeltzProstetnic/agent-fleet/main/setup/install-windows.ps1 | iex

.NOTES
    Requires: Windows 10 version 2004+ or Windows 11
    Installs: WSL2, Ubuntu 24.04, Node.js 22, Claude Code, agent-fleet
    Duration: 10-20 minutes (depending on download speeds)
    Restarts: May require one restart for WSL enablement
#>

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "   OK: $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "   WARN: $msg" -ForegroundColor Yellow }

Write-Host @"

    ╔══════════════════════════════════════╗
    ║   Agent Fleet — Windows Installer    ║
    ║   v1.0                               ║
    ╚══════════════════════════════════════╝

"@ -ForegroundColor Cyan

# ── Step 1: Check Windows version ──
Write-Step "Checking Windows version..."
$build = [System.Environment]::OSVersion.Version.Build
if ($build -lt 19041) {
    Write-Host "ERROR: Windows 10 version 2004+ or Windows 11 required (build 19041+). You have build $build." -ForegroundColor Red
    exit 1
}
Write-Ok "Windows build $build"

# ── Step 2: Enable WSL if needed ──
Write-Step "Checking WSL..."
$wslInstalled = $false
try {
    $wslVersion = wsl --version 2>&1
    if ($LASTEXITCODE -eq 0) { $wslInstalled = $true }
} catch {}

if (-not $wslInstalled) {
    Write-Step "Installing WSL2 (this may require a restart)..."
    wsl --install --no-distribution
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: WSL installation failed. Try running 'wsl --install' manually." -ForegroundColor Red
        exit 1
    }
    Write-Warn "WSL installed. If prompted to restart, do so and run this script again."
}
Write-Ok "WSL2 available"

# ── Step 3: Install Ubuntu 24.04 if no distro exists ──
Write-Step "Checking for Linux distribution..."
$distros = wsl --list --quiet 2>$null
$hasUbuntu = $distros | Where-Object { $_ -match "Ubuntu" }

if (-not $hasUbuntu) {
    Write-Step "Installing Ubuntu 24.04 (this downloads ~600MB)..."
    wsl --install -d Ubuntu-24.04
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Ubuntu installation failed." -ForegroundColor Red
        exit 1
    }
    Write-Ok "Ubuntu 24.04 installed"
    Write-Host "`n   You'll be asked to create a Linux username and password." -ForegroundColor Yellow
    Write-Host "   After that, this script will continue setup inside WSL." -ForegroundColor Yellow
    Write-Host "   Press Enter when Ubuntu setup is complete..." -ForegroundColor Yellow
    Read-Host
} else {
    Write-Ok "Ubuntu found"
}

# ── Step 4: Run setup inside WSL ──
Write-Step "Setting up agent-fleet inside WSL..."

$wslScript = @'
#!/bin/bash
set -e

echo ""
echo ">> Installing prerequisites..."

# Update packages
sudo apt-get update -qq

# Install git if missing
if ! command -v git &>/dev/null; then
    sudo apt-get install -y -qq git
    echo "   OK: git installed"
else
    echo "   OK: git already installed"
fi

# Install Node.js 22 if missing
if ! command -v node &>/dev/null || [[ "$(node --version 2>/dev/null)" != v22* ]]; then
    echo ">> Installing Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null 2>&1
    sudo apt-get install -y -qq nodejs
    echo "   OK: Node.js $(node --version) installed"
else
    echo "   OK: Node.js $(node --version) already installed"
fi

# Install Claude Code if missing
if ! command -v claude &>/dev/null; then
    echo ">> Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code 2>/dev/null
    echo "   OK: Claude Code installed"
else
    echo "   OK: Claude Code already installed"
fi

# Clone agent-fleet if not present
if [ ! -d "$HOME/agent-fleet" ]; then
    echo ">> Cloning agent-fleet..."
    git clone https://github.com/JeltzProstetnic/agent-fleet "$HOME/agent-fleet"
    echo "   OK: agent-fleet cloned to ~/agent-fleet"
else
    echo "   OK: ~/agent-fleet already exists"
fi

# Run setup
echo ""
echo ">> Running agent-fleet setup..."
cd "$HOME/agent-fleet"
bash setup.sh

echo ""
echo "============================================"
echo "  Agent Fleet installed successfully!"
echo ""
echo "  To start: open Ubuntu terminal and type:"
echo "    claude"
echo ""
echo "  First run will guide you through setup."
echo "============================================"
'@

# Write the script to a temp file and run in WSL
$tempFile = [System.IO.Path]::GetTempFileName()
$wslScript | Set-Content -Path $tempFile -Encoding UTF8 -NoNewline
$wslPath = wsl wslpath -u ($tempFile -replace '\\', '/')
wsl bash $wslPath
Remove-Item $tempFile -ErrorAction SilentlyContinue

Write-Host @"

    ╔══════════════════════════════════════╗
    ║   Installation Complete!             ║
    ║                                      ║
    ║   Open Ubuntu terminal and type:     ║
    ║     claude                           ║
    ╚══════════════════════════════════════╝

"@ -ForegroundColor Green
