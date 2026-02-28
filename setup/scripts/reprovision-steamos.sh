#!/usr/bin/env bash
# reprovision-steamos.sh — Restore system packages after SteamOS update
#
# SteamOS overwrites the root filesystem on updates, wiping pacman packages.
# Everything in $HOME survives (NVM, Node, Claude Code, config).
# This script re-installs only the system-level deps.
#
# Usage: bash ~/agent-fleet/setup/scripts/reprovision-steamos.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo -e "${GREEN}=== SteamOS Re-provisioning ===${NC}"
echo ""

# Check we're on SteamOS
if [[ ! -f /etc/os-release ]] || ! grep -qi steam /etc/os-release 2>/dev/null; then
    log_warn "This doesn't look like SteamOS. Proceeding anyway..."
fi

# ---------------------------------------------------------------------------
# Step 1: Re-enable sshd (may be disabled after update)
# ---------------------------------------------------------------------------
log_info "Checking sshd..."
if systemctl is-active --quiet sshd 2>/dev/null; then
    log_info "sshd is already running"
else
    log_info "Enabling and starting sshd..."
    sudo systemctl enable sshd
    sudo systemctl start sshd
fi

# ---------------------------------------------------------------------------
# Step 2: Pacman packages
# ---------------------------------------------------------------------------
log_info "Disabling read-only filesystem..."
sudo steamos-readonly disable 2>/dev/null || log_warn "steamos-readonly not available"

# Initialize keyring if needed
if ! sudo pacman-key --list-keys &>/dev/null 2>&1; then
    log_info "Initializing pacman keyring..."
    sudo pacman-key --init
    sudo pacman-key --populate archlinux holo 2>/dev/null || sudo pacman-key --populate archlinux
fi

log_info "Installing packages..."
# Must match _install_deps_arch() in install-base.sh, plus jq
sudo pacman -Sy --noconfirm --needed \
    jq base-devel \
    socat bubblewrap curl git \
    python python-pip python-pipx \
    2>/dev/null || log_warn "Some packages may have failed (SteamOS repos are a subset of Arch)"

log_info "Re-enabling read-only filesystem..."
sudo steamos-readonly enable 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 3: Verify $HOME tools survived
# ---------------------------------------------------------------------------
echo ""
log_info "Verifying tools..."

# Source NVM
export NVM_DIR="${HOME}/.nvm"
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:$PATH"

checks_passed=true

if command -v node &>/dev/null; then
    log_info "Node.js: $(node -v)"
else
    log_error "Node.js not found -- run: nvm install 22"
    checks_passed=false
fi

if command -v mclaude &>/dev/null; then
    log_info "mclaude: found at $(command -v mclaude)"
else
    log_error "mclaude not found -- check ~/.local/bin/mclaude"
    checks_passed=false
fi

if command -v jq &>/dev/null; then
    log_info "jq: $(jq --version)"
else
    log_warn "jq not installed (pacman step may have failed)"
fi

echo ""
if [[ "$checks_passed" == true ]]; then
    echo -e "${GREEN}=== Re-provisioning complete. All tools verified. ===${NC}"
else
    echo -e "${YELLOW}=== Re-provisioning done with warnings. Check errors above. ===${NC}"
fi
