#!/usr/bin/env bash
#
# install.sh - WSL Claude Code Unified Installer
# ================================================
# Single entry point that orchestrates install-base.sh and configure-claude.sh.
#
# Workflow:
#   1. Preview Phase 1 (base system) via dry-run
#   2. Describe Phase 2 (Claude configuration)
#   3. Ask user to confirm
#   4. Execute Phase 1 for real
#   5. Execute Phase 2 for real (prompts for MCP credentials if needed)
#
# Usage:
#   bash install.sh [options]
#
# Options:
#   --dry-run          Show preview only, don't offer to execute
#   --verbose, -v      Pass verbose mode to sub-scripts
#   --no-color         Disable colored output
#   --reconfigure-mcp  Force re-prompting for MCP credentials
#   --rollback         Restore from most recent backup (does not install)
#   --help, -h         Show this help message
#

set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared utilities
source "${SCRIPT_DIR}/lib.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

DRY_RUN_ONLY=false
RECONFIGURE_MCP=false
ROLLBACK_MODE=false
COMMON_ARGS=()
CONFIGURE_ARGS=()

# ============================================================================
# HELP TEXT
# ============================================================================

show_help() {
    cat << 'EOF'
install.sh - WSL Claude Code Unified Installer

Single entry point for setting up Claude Code on WSL with cc-mirror.

WORKFLOW:
  1. Shows a preview of what Phase 1 (base system) would install
  2. Describes what Phase 2 (Claude configuration) will do
  3. Asks for confirmation before making any changes
  4. Runs Phase 1: system deps, Node.js, npm config, cc-mirror, mclaude variant
  5. Runs Phase 2: VoltAgent, MCP servers, launcher patches, helper scripts

USAGE:
  bash install.sh [options]

OPTIONS:
  --dry-run          Show preview only, don't offer to execute
  --verbose, -v      Show detailed output from sub-scripts
  --no-color         Disable colored output
  --reconfigure-mcp  Force re-prompting for MCP credentials in Phase 2
  --rollback         Restore from most recent backup (does not install)
  --help, -h         Show this help message

NOTES:
  - Phase 2 will prompt for MCP credentials (GitHub PAT, Jira token)
    during execution, not during preview
  - Both phases are idempotent (safe to re-run)
  - Phase 1 requires sudo for apt-get operations
  - If only Phase 2 needs re-running, use: bash configure-claude.sh

EOF
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN_ONLY=true
            shift
            ;;
        --verbose|-v)
            COMMON_ARGS+=(--verbose)
            VERBOSE=true
            shift
            ;;
        --no-color)
            COMMON_ARGS+=(--no-color)
            NO_COLOR=true
            shift
            ;;
        --reconfigure-mcp)
            RECONFIGURE_MCP=true
            CONFIGURE_ARGS+=(--reconfigure-mcp)
            shift
            ;;
        --rollback)
            ROLLBACK_MODE=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            log_warn "Unknown argument: $1"
            shift
            ;;
    esac
done

# ============================================================================
# ROLLBACK MODE
# ============================================================================

if [[ "${ROLLBACK_MODE}" == "true" ]]; then
    # Initialize logging (needed for rollback functions)
    log_init

    print_header "Rollback Mode"

    # Show available backups
    rollback_show
    echo ""

    # Prompt for confirmation
    if ! prompt_yes_no "Restore from most recent backup?" "n"; then
        echo ""
        log_info "Rollback cancelled by user."
        exit 0
    fi

    echo ""

    # Perform rollback
    rollback_last

    echo ""
    log_success "Rollback completed. Please verify your system state."
    exit 0
fi

# ============================================================================
# PREVIEW
# ============================================================================

# Initialize logging (needed for log_warn/log_info to work under set -e)
log_init

print_header "WSL Claude Code Setup - Preview"

echo "This installer will set up Claude Code on WSL in two phases."
echo ""

# --- Phase 1 Preview: Run install-base.sh --dry-run ---

echo -e "${COLOR_BOLD}${COLOR_BLUE}--- Phase 1: Base System Setup (dry-run preview) ---${COLOR_RESET}"
echo ""

if ! bash "${SCRIPT_DIR}/install-base.sh" --dry-run "${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"}"; then
    log_warn "Phase 1 dry-run exited with errors (this can happen when nvm is"
    log_warn "already installed). The actual installation may still succeed."
    echo ""
fi

# --- Phase 2 Preview: Describe configure-claude.sh ---
# We don't run configure-claude.sh --dry-run here because it has interactive
# credential prompts. Instead, show a description of what it will do.

echo ""
echo -e "${COLOR_BOLD}${COLOR_BLUE}--- Phase 2: Claude Configuration (will run after Phase 1) ---${COLOR_RESET}"
echo ""
echo "  Phase 2 will:"
echo "    1. Deploy VoltAgent subagents configuration"
echo "    2. Configure MCP servers (GitHub, Jira, Serena)"
echo "       - Will prompt for credentials if not already configured"
echo "    3. Patch mclaude launcher (MCP enablement + update-checker)"
echo "    4. Deploy helper scripts"
echo "    5. Deploy global CLAUDE.md"
echo "    6. Configure WSL settings (git, credentials, bashrc)"
echo ""

if [[ "${RECONFIGURE_MCP}" == "true" ]]; then
    echo -e "  ${COLOR_YELLOW}--reconfigure-mcp: Will re-prompt for MCP credentials${COLOR_RESET}"
    echo ""
fi

# ============================================================================
# DRY-RUN EXIT
# ============================================================================

if [[ "${DRY_RUN_ONLY}" == "true" ]]; then
    echo -e "${COLOR_YELLOW}${COLOR_BOLD}DRY RUN MODE - Preview only, no changes made.${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Run without --dry-run to install.${COLOR_RESET}"
    exit 0
fi

# ============================================================================
# CONFIRMATION
# ============================================================================

echo -e "${COLOR_BOLD}Ready to install.${COLOR_RESET}"
echo ""
echo "  Phase 1 requires sudo for apt-get package installation."
echo "  Phase 2 will prompt for MCP credentials (GitHub PAT, Jira token)."
echo ""

if ! prompt_yes_no "Proceed with installation?" "y"; then
    echo ""
    log_info "Installation cancelled by user."
    exit 0
fi

echo ""

# ============================================================================
# PHASE 1: BASE SYSTEM
# ============================================================================

print_header "Phase 1: Base System Setup"

bash "${SCRIPT_DIR}/install-base.sh" "${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"}"

# Source bashrc to pick up nvm/node installed by Phase 1.
# This is needed because configure-claude.sh requires node and npm.
export NVM_DIR="${HOME}/.nvm"
# shellcheck disable=SC1091
[[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"
export PATH="${HOME}/.npm-global/bin:${PATH}"

# Verify node is available before Phase 2
if ! command -v node &>/dev/null; then
    log_error "Node.js not found after Phase 1. You may need to open a new terminal."
    log_error "Then run: bash ${SCRIPT_DIR}/configure-claude.sh"
    exit 1
fi

# ============================================================================
# PHASE 2: CLAUDE CONFIGURATION
# ============================================================================

print_header "Phase 2: Claude Configuration"

bash "${SCRIPT_DIR}/configure-claude.sh" \
    "${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"}" \
    "${CONFIGURE_ARGS[@]+"${CONFIGURE_ARGS[@]}"}"

# ============================================================================
# FINAL SUMMARY
# ============================================================================

print_header "Installation Complete!"

echo "Both phases completed successfully."
echo ""
echo -e "${COLOR_BLUE}${COLOR_BOLD}To get started:${COLOR_RESET}"
echo "  1. Open a new terminal (or run: source ~/.bashrc)"
echo "  2. Run: mclaude"
echo ""
echo -e "${COLOR_BLUE}Logs:${COLOR_RESET}"
echo "  Check ~/.claude-setup/logs/ for detailed logs"
echo ""
