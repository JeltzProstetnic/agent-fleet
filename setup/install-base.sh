#!/usr/bin/env bash
#
# install-base.sh - Claude Code Base System Setup
# =================================================
# Installs system dependencies, Node.js (via nvm), npm config, and cc-mirror.
# This is phase 1 of the setup - run this before configure-claude.sh.
#
# Supported platforms:
#   - Debian/Ubuntu (including WSL)
#   - Arch Linux / SteamOS (Steam Deck)
#   - Fedora / RHEL (best-effort)
#
# This script handles:
#   1. Environment detection (distro, WSL, SteamOS)
#   2. System dependencies (apt/pacman/dnf)
#   3. Node.js via nvm
#   4. npm global prefix configuration
#   5. cc-mirror installation
#
# Usage:
#   bash install-base.sh [options]
#
# Options:
#   --dry-run        Show what would be done without making changes
#   --verbose, -v    Show detailed output
#   --no-color       Disable colored output
#   --help, -h       Show this help message
#
# Next steps after running this script:
#   Run configure-claude.sh to set up mclaude variant, MCP servers, and agents
#

set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared utilities
source "${SCRIPT_DIR}/lib.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

readonly NVM_VERSION="v0.40.3"
readonly NODE_VERSION="22"
readonly CC_MIRROR_VARIANT="mclaude"
readonly TOTAL_STEPS=6

# Track installation progress
declare -a INSTALLED_STEPS=()
declare -a SKIPPED_STEPS=()

# ============================================================================
# HELP TEXT
# ============================================================================

show_help() {
    cat << 'EOF'
install-base.sh - Claude Code Base System Setup

This script installs the foundation for Claude Code:
  - System dependencies (socat, bubblewrap, curl, git, etc.)
  - Node.js (via nvm) with user-local npm configuration
  - cc-mirror (npm package for Claude Code variant management)

Supported platforms: Debian/Ubuntu (including WSL), Arch/SteamOS, Fedora/RHEL.

This is PHASE 1 of the setup. After this completes, run configure-claude.sh
to set up the mclaude variant, MCP servers, and VoltAgent subagents.

USAGE:
  bash install-base.sh [options]

OPTIONS:
  --dry-run        Show what would be done without making changes
  --verbose, -v    Show detailed command output
  --no-color       Disable colored output
  --help, -h       Show this help message

REQUIREMENTS:
  - Supported Linux distribution (or manual dependency installation)
  - sudo access for package installation
  - Internet connection for downloads

WHAT GETS INSTALLED:
  1. System packages: socat, bubblewrap, curl, git, build tools, python3, pipx
  2. NVM (Node Version Manager) v0.40.3
  3. Node.js v22 (via nvm)
  4. npm global prefix configured to ~/.npm-global
  5. cc-mirror package (globally via npm)
  6. mclaude variant (via cc-mirror create)

NEXT STEPS:
  After this script completes successfully:
    1. Open a new terminal (or: source ~/.bashrc)
    2. Run: bash configure-claude.sh

NOTES:
  - All steps are idempotent (safe to re-run)
  - Existing installations are detected and skipped
  - sudo password will be required for package operations
  - No credentials needed for this phase (credentials in configure-claude.sh)
  - On SteamOS: system packages may need re-installation after OS updates
    (use reprovision-steamos.sh for recovery)

EOF
}

# ============================================================================
# STEP 1: ENVIRONMENT CHECK
# ============================================================================

check_environment() {
    log_step 1 "${TOTAL_STEPS}" "Verify Environment"

    local distro
    distro=$(detect_distro)

    if is_wsl; then
        log_info "Running on WSL (distro family: ${distro})"
    elif is_steamos; then
        log_info "Running on SteamOS (Arch-based, immutable root FS)"
        log_warn "System packages installed via pacman will be lost on OS updates"
        log_warn "Use reprovision-steamos.sh to re-install after SteamOS updates"
    else
        log_info "Running on native Linux (distro family: ${distro})"
    fi

    if [[ "${distro}" == "unknown" ]]; then
        log_warn "Unrecognized distribution — package installation will be skipped"
        log_warn "You may need to install dependencies manually (see --help)"
    fi

    INSTALLED_STEPS+=("environment-check (${distro})")
    log_success "Environment check complete"
}

# ============================================================================
# STEP 2: SYSTEM DEPENDENCIES
# ============================================================================

install_system_deps() {
    log_step 2 "${TOTAL_STEPS}" "Install System Dependencies"

    local distro
    distro=$(detect_distro)

    case "${distro}" in
        debian) _install_deps_debian ;;
        arch)   _install_deps_arch ;;
        fedora) _install_deps_fedora ;;
        *)
            log_warn "Unsupported distro family: ${distro}"
            log_warn "Please install these manually: socat bubblewrap curl git python3 pipx"
            log_warn "Plus build tools (gcc, make) and python3-pip"
            SKIPPED_STEPS+=("system-deps (unsupported distro, manual install needed)")
            return 0
            ;;
    esac

    log_success "System dependencies installed"
}

_install_deps_debian() {
    local packages=(
        socat
        bubblewrap
        curl
        git
        build-essential
        python3
        python3-pip
        pipx
    )

    local needed_packages=()
    for pkg in "${packages[@]}"; do
        if ! check_pkg_installed "${pkg}"; then
            needed_packages+=("${pkg}")
        else
            [[ "${VERBOSE}" == "true" ]] && log_info "Package already installed: ${pkg}"
        fi
    done

    if [[ ${#needed_packages[@]} -eq 0 ]]; then
        log_info "All required system packages already installed"
        SKIPPED_STEPS+=("system-deps (already installed)")
        return 0
    fi

    log_info "Need to install ${#needed_packages[@]} package(s): ${needed_packages[*]}"

    if [[ "${DRY_RUN}" == "false" ]]; then
        log_info "Updating package lists (requires sudo)..."
        sudo apt-get update -qq || {
            log_error "Failed to update package lists"
            exit 1
        }

        log_info "Installing packages (requires sudo)..."
        sudo apt-get install -y -qq "${needed_packages[@]}" || {
            log_error "Failed to install system packages"
            exit 1
        }

        run_cmd pipx ensurepath 2>/dev/null || true
        INSTALLED_STEPS+=("system-deps (apt)")
    else
        log_info "[DRY RUN] Would run: sudo apt-get update -qq"
        log_info "[DRY RUN] Would run: sudo apt-get install -y -qq ${needed_packages[*]}"
        log_info "[DRY RUN] Would run: pipx ensurepath"
        INSTALLED_STEPS+=("system-deps (dry-run)")
    fi
}

_install_deps_arch() {
    local packages=(
        socat
        bubblewrap
        curl
        git
        base-devel
        python
        python-pip
        python-pipx
    )

    local needed_packages=()
    for pkg in "${packages[@]}"; do
        if ! check_pkg_installed "${pkg}"; then
            needed_packages+=("${pkg}")
        else
            [[ "${VERBOSE}" == "true" ]] && log_info "Package already installed: ${pkg}"
        fi
    done

    if [[ ${#needed_packages[@]} -eq 0 ]]; then
        log_info "All required system packages already installed"
        SKIPPED_STEPS+=("system-deps (already installed)")
        return 0
    fi

    log_info "Need to install ${#needed_packages[@]} package(s): ${needed_packages[*]}"

    if [[ "${DRY_RUN}" == "false" ]]; then
        # SteamOS has an immutable root FS — must disable read-only mode
        if is_steamos; then
            log_info "SteamOS detected: disabling read-only filesystem..."
            sudo steamos-readonly disable || {
                log_error "Failed to disable SteamOS read-only mode"
                exit 1
            }

            # Initialize pacman keyring if needed (fresh SteamOS installs)
            if ! pacman-key --list-keys &>/dev/null; then
                log_info "Initializing pacman keyring..."
                sudo pacman-key --init
                sudo pacman-key --populate archlinux
            fi
        fi

        log_info "Installing packages via pacman (requires sudo)..."
        sudo pacman -S --noconfirm --needed "${needed_packages[@]}" || {
            log_error "Failed to install system packages"
            # Re-enable read-only on SteamOS even on failure
            is_steamos && sudo steamos-readonly enable 2>/dev/null || true
            exit 1
        }

        # Re-enable read-only FS on SteamOS
        if is_steamos; then
            log_info "Re-enabling SteamOS read-only filesystem..."
            sudo steamos-readonly enable || true
            echo ""
            log_info "NOTE: SteamOS system packages are lost on OS updates."
            log_info "      After a SteamOS update, run: bash reprovision-steamos.sh"
        fi

        run_cmd pipx ensurepath 2>/dev/null || true
        INSTALLED_STEPS+=("system-deps (pacman)")
    else
        is_steamos && log_info "[DRY RUN] Would run: sudo steamos-readonly disable"
        log_info "[DRY RUN] Would run: sudo pacman -S --noconfirm --needed ${needed_packages[*]}"
        is_steamos && log_info "[DRY RUN] Would run: sudo steamos-readonly enable"
        log_info "[DRY RUN] Would run: pipx ensurepath"
        INSTALLED_STEPS+=("system-deps (dry-run)")
    fi
}

_install_deps_fedora() {
    local packages=(
        socat
        bubblewrap
        curl
        git
        gcc
        gcc-c++
        make
        python3
        python3-pip
        pipx
    )

    local needed_packages=()
    for pkg in "${packages[@]}"; do
        if ! check_pkg_installed "${pkg}"; then
            needed_packages+=("${pkg}")
        else
            [[ "${VERBOSE}" == "true" ]] && log_info "Package already installed: ${pkg}"
        fi
    done

    if [[ ${#needed_packages[@]} -eq 0 ]]; then
        log_info "All required system packages already installed"
        SKIPPED_STEPS+=("system-deps (already installed)")
        return 0
    fi

    log_info "Need to install ${#needed_packages[@]} package(s): ${needed_packages[*]}"

    if [[ "${DRY_RUN}" == "false" ]]; then
        log_info "Installing packages via dnf (requires sudo)..."
        sudo dnf install -y "${needed_packages[@]}" || {
            log_error "Failed to install system packages"
            exit 1
        }

        run_cmd pipx ensurepath 2>/dev/null || true
        INSTALLED_STEPS+=("system-deps (dnf)")
    else
        log_info "[DRY RUN] Would run: sudo dnf install -y ${needed_packages[*]}"
        log_info "[DRY RUN] Would run: pipx ensurepath"
        INSTALLED_STEPS+=("system-deps (dry-run)")
    fi
}

# ============================================================================
# STEP 3: NODE.JS VIA NVM
# ============================================================================

install_nodejs() {
    log_step 3 "${TOTAL_STEPS}" "Install Node.js via NVM"

    export NVM_DIR="${HOME}/.nvm"

    # Check if nvm is already installed
    if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
        log_info "NVM already installed at ${NVM_DIR}"
        source "${NVM_DIR}/nvm.sh"

        # Check if correct Node version is installed
        if nvm list | grep -q "${NODE_VERSION}"; then
            local current_version
            current_version=$(node --version 2>/dev/null || echo "none")
            log_info "Node.js ${NODE_VERSION} already installed (current: ${current_version})"

            # Make sure it's the default
            if ! nvm list | grep -q "default -> ${NODE_VERSION}"; then
                log_info "Setting Node.js ${NODE_VERSION} as default..."
                run_cmd nvm alias default "${NODE_VERSION}"
            fi

            SKIPPED_STEPS+=("nodejs (already installed)")
            log_success "Node.js verified"
            return 0
        fi
    else
        # Install nvm
        require_cmd curl "apt-get install curl"

        log_info "Installing NVM ${NVM_VERSION}..."
        if [[ "${DRY_RUN}" == "false" ]]; then
            curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash || {
                log_error "Failed to install NVM"
                exit 1
            }
            source "${NVM_DIR}/nvm.sh"
        else
            log_info "[DRY RUN] Would download and install NVM ${NVM_VERSION}"
        fi
    fi

    # Install Node.js
    log_info "Installing Node.js ${NODE_VERSION}..."
    if [[ "${DRY_RUN}" == "false" ]]; then
        nvm install "${NODE_VERSION}" || {
            log_error "Failed to install Node.js ${NODE_VERSION}"
            exit 1
        }
        nvm use "${NODE_VERSION}"
        nvm alias default "${NODE_VERSION}"

        local installed_version
        installed_version=$(node --version)
        log_info "Node.js ${installed_version} installed successfully"
        INSTALLED_STEPS+=("nodejs")
    else
        log_info "[DRY RUN] Would run: nvm install ${NODE_VERSION}"
        log_info "[DRY RUN] Would run: nvm use ${NODE_VERSION}"
        log_info "[DRY RUN] Would run: nvm alias default ${NODE_VERSION}"
        INSTALLED_STEPS+=("nodejs (dry-run)")
    fi

    log_success "Node.js installation complete"
}

# ============================================================================
# STEP 4: NPM GLOBAL PREFIX
# ============================================================================

setup_npm_global() {
    log_step 4 "${TOTAL_STEPS}" "Configure npm for User-Local Installations"

    local npm_global="${HOME}/.npm-global"
    local bashrc="${HOME}/.bashrc"

    # Create npm-global directory
    if [[ ! -d "${npm_global}" ]]; then
        log_info "Creating ${npm_global}..."
        run_cmd mkdir -p "${npm_global}"
    else
        log_info "Directory ${npm_global} already exists"
    fi

    # Check current npm prefix
    local current_prefix
    current_prefix=$(npm config get prefix 2>/dev/null || echo "")

    if [[ "${current_prefix}" == "${npm_global}" ]]; then
        log_info "npm prefix already configured to ${npm_global}"
    else
        log_info "Setting npm prefix to ${npm_global}..."
        run_cmd npm config set prefix "${npm_global}"
        INSTALLED_STEPS+=("npm-prefix")
    fi

    # Add to PATH in .bashrc if not already present
    if file_contains "${bashrc}" "npm-global/bin"; then
        log_info "npm-global already in PATH (found in .bashrc)"
    else
        log_info "Adding npm-global to PATH in .bashrc..."

        backup_file "${bashrc}"

        if [[ "${DRY_RUN}" == "false" ]]; then
            cat >> "${bashrc}" << 'BASHRC_SNIPPET'

# npm global packages
export PATH="$HOME/.npm-global/bin:$PATH"
BASHRC_SNIPPET
            log_info "Added npm-global to PATH"
            INSTALLED_STEPS+=("bashrc-npm-path")
        else
            log_info "[DRY RUN] Would append npm-global PATH to .bashrc"
        fi
    fi

    # Export for current session
    export PATH="${npm_global}/bin:${PATH}"

    log_success "npm configuration complete"
}

# ============================================================================
# STEP 5: CC-MIRROR
# ============================================================================

install_cc_mirror() {
    log_step 5 "${TOTAL_STEPS}" "Install cc-mirror"

    # Warn if native Claude Code binary conflicts with cc-mirror
    if [[ -f "${HOME}/.local/bin/claude" ]]; then
        if ! grep -q "cc-mirror" "${HOME}/.local/bin/claude" 2>/dev/null; then
            log_warn "Native Claude Code binary detected at ~/.local/bin/claude"
            log_warn "This can conflict with cc-mirror. Consider removing it:"
            log_warn "  rm ~/.local/bin/claude"
            echo ""
        fi
    fi

    # Check if cc-mirror is already installed
    if command -v cc-mirror &> /dev/null; then
        local current_version
        current_version=$(npm list -g cc-mirror --depth=0 2>/dev/null | grep cc-mirror | sed 's/.*@//' || echo "unknown")
        log_info "cc-mirror already installed (version: ${current_version})"

        log_info "Checking for updates..."
        if [[ "${DRY_RUN}" == "false" ]]; then
            npm update -g cc-mirror 2>/dev/null || npm install -g cc-mirror || {
                log_warn "Failed to update cc-mirror (continuing with existing version)"
            }
        else
            log_info "[DRY RUN] Would run: npm update -g cc-mirror"
        fi

        SKIPPED_STEPS+=("cc-mirror (already installed)")
    else
        log_info "Installing cc-mirror from npm..."
        if [[ "${DRY_RUN}" == "false" ]]; then
            npm install -g cc-mirror || {
                log_error "Failed to install cc-mirror"
                exit 1
            }
            INSTALLED_STEPS+=("cc-mirror")
        else
            log_info "[DRY RUN] Would run: npm install -g cc-mirror"
            INSTALLED_STEPS+=("cc-mirror (dry-run)")
        fi
    fi

    log_info "Note: Ignore any 'switched to native installer' messages from Claude Code"
    log_info "      cc-mirror requires the npm installation method"

    log_success "cc-mirror installation complete"
}

# ============================================================================
# STEP 6: CREATE MCLAUDE VARIANT
# ============================================================================

create_mclaude_variant() {
    log_step 6 "${TOTAL_STEPS}" "Create mclaude Variant"

    # Check if mclaude launcher already exists
    if [[ -f "${HOME}/.local/bin/mclaude" ]]; then
        log_info "mclaude launcher already exists at ~/.local/bin/mclaude"
        SKIPPED_STEPS+=("mclaude-variant (already exists)")
        log_success "mclaude variant verified"
        return 0
    fi

    log_info "Creating mclaude variant with team mode..."
    if [[ "${DRY_RUN}" == "false" ]]; then
        run_cmd cc-mirror create "${CC_MIRROR_VARIANT}" --team-mode || {
            log_error "Failed to create mclaude variant"
            exit 1
        }

        # Verify launcher was created
        if [[ ! -f "${HOME}/.local/bin/mclaude" ]]; then
            log_error "mclaude launcher not found after creation"
            exit 1
        fi

        log_info "mclaude launcher created at ~/.local/bin/mclaude"
        INSTALLED_STEPS+=("mclaude-variant")
    else
        log_info "[DRY RUN] Would run: cc-mirror create ${CC_MIRROR_VARIANT} --team-mode"
        INSTALLED_STEPS+=("mclaude-variant (dry-run)")
    fi

    log_success "mclaude variant created"
}

# ============================================================================
# SUMMARY
# ============================================================================

print_summary() {
    print_header "Base Installation Complete"

    if [[ ${#INSTALLED_STEPS[@]} -gt 0 ]]; then
        echo -e "${COLOR_GREEN}${COLOR_BOLD}Installed/configured:${COLOR_RESET}"
        for step in "${INSTALLED_STEPS[@]}"; do
            echo -e "  ${COLOR_GREEN}✓${COLOR_RESET} ${step}"
        done
        echo ""
    fi

    if [[ ${#SKIPPED_STEPS[@]} -gt 0 ]]; then
        echo -e "${COLOR_BLUE}Skipped (already present):${COLOR_RESET}"
        for step in "${SKIPPED_STEPS[@]}"; do
            echo -e "  ${COLOR_BLUE}•${COLOR_RESET} ${step}"
        done
        echo ""
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${COLOR_YELLOW}${COLOR_BOLD}DRY RUN MODE - No changes were made${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}Run without --dry-run to perform actual installation${COLOR_RESET}"
        echo ""
    else
        echo -e "${COLOR_GREEN}${COLOR_BOLD}Base system setup is complete!${COLOR_RESET}"
        echo ""
        echo -e "${COLOR_BLUE}${COLOR_BOLD}NEXT STEPS:${COLOR_RESET}"
        echo "  1. Open a new terminal (or run: source ~/.bashrc)"
        echo "  2. Verify installation:"
        echo "       node --version    # Should show v22.x.x"
        echo "       npm --version     # Should show 10.x.x"
        echo "       cc-mirror --help  # Should show cc-mirror commands"
        echo "  3. Run the configuration script:"
        echo "       cd ${SCRIPT_DIR}"
        echo "       bash configure-claude.sh"
        echo ""
        echo -e "${COLOR_BLUE}What configure-claude.sh will do:${COLOR_RESET}"
        echo "  - Install VoltAgent subagents (100+ specialized agents)"
        echo "  - Set up MCP servers (GitHub, Jira, Serena)"
        echo "  - Configure platform-specific settings"
        echo "  - Deploy helper scripts and documentation"
        echo ""
    fi
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    # Set up error trap for cleanup
    trap 'log_error "Installation interrupted. Check log file for details."' ERR INT TERM

    # Parse command-line arguments
    if ! parse_common_args "$@"; then
        show_help
        exit 0
    fi

    # Initialize logging
    log_init

    print_header "Claude Code - Base Installation"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
        echo ""
    fi

    log_info "This script will install:"
    log_info "  1. System dependencies (requires sudo)"
    log_info "  2. Node.js via nvm"
    log_info "  3. npm global prefix configuration"
    log_info "  4. cc-mirror package"
    log_info "  5. mclaude variant creation"
    echo ""
    log_info "Configuration: NVM ${NVM_VERSION}, Node.js ${NODE_VERSION}"
    log_info "Variant name: ${CC_MIRROR_VARIANT}"
    echo ""

    # Run installation steps
    check_environment
    install_system_deps
    install_nodejs
    setup_npm_global
    install_cc_mirror
    create_mclaude_variant

    # Show summary
    print_summary
}

main "$@"
