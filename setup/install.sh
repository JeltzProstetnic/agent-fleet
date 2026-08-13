#!/usr/bin/env bash
#
# install.sh - Claude Code Unified Installer
# ============================================
# Single entry point that orchestrates install-base.sh and configure-claude.sh.
# Supports Debian/Ubuntu, Arch/SteamOS, Fedora/RHEL, and macOS.
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
#   --skip-preflight   Skip pre-installation system checks
#   --rollback         Restore from most recent backup (does not install)
#   --help, -h         Show this help message
#

set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"  # The config repo root (cfg-agent-fleet or agent-fleet clone)

# Source shared utilities
source "${SCRIPT_DIR}/lib.sh"

# ============================================================================
# TEMPLATE MARKER CLEANUP
# ============================================================================
# .template-repo marks this as an uninitialized template clone. Remove it
# before anything else — hooks check for it and warn if present.

if [[ -f "${CONFIG_REPO_ROOT}/.template-repo" ]]; then
    echo "Removing template marker (.template-repo)..."
    rm -f "${CONFIG_REPO_ROOT}/.template-repo"
    # Create .setup-pending to trigger first-run refinement on next Claude session
    if [[ ! -f "${CONFIG_REPO_ROOT}/.setup-pending" ]]; then
        touch "${CONFIG_REPO_ROOT}/.setup-pending"
        echo "Created .setup-pending marker (triggers first-run configuration)."
    fi
fi

# ============================================================================
# ORIGIN REMOTE SAFETY
# ============================================================================
# If origin points to the template repo, rename it to 'upstream' and remove
# origin. This prevents accidental pushes back to the template. The user's
# own repo will be set as origin during first-run refinement (or manually).

_origin_url=$(git -C "${CONFIG_REPO_ROOT}" remote get-url origin 2>/dev/null || echo "")

# Template origin patterns — used to detect when origin points to the upstream
# template (not a user's fork). Resolution order:
#   1. .template-orgs file in repo root (one pattern per line, gitignored)
#   2. TEMPLATE_ORGS environment variable (pipe-separated patterns)
#   3. Generic default: matches any repo named "agent-fleet" (not a fork name)
_template_patterns=""
if [[ -f "${CONFIG_REPO_ROOT}/.template-orgs" ]]; then
    # Read patterns from file, join with | for grep -E
    _template_patterns=$(grep -v '^#' "${CONFIG_REPO_ROOT}/.template-orgs" | grep -v '^\s*$' | tr '\n' '|' | sed 's/|$//')
fi
if [[ -z "${_template_patterns}" && -n "${TEMPLATE_ORGS:-}" ]]; then
    _template_patterns="${TEMPLATE_ORGS}"
fi
# Fallback: match the canonical template repo pattern
: "${_template_patterns:=agent-fleet-template/agent-fleet}"

if [[ -n "${_origin_url}" ]] && echo "${_origin_url}" | grep -qE "${_template_patterns}"; then
    echo "Origin points to the template repo — renaming to 'upstream'..."
    # Only add upstream if it doesn't already exist
    if ! git -C "${CONFIG_REPO_ROOT}" remote get-url upstream &>/dev/null; then
        git -C "${CONFIG_REPO_ROOT}" remote rename origin upstream
    else
        # upstream already exists, just remove origin
        git -C "${CONFIG_REPO_ROOT}" remote remove origin
    fi
    echo "  Done. 'upstream' now tracks the template for updates."
    echo "  Your own repo will be set as 'origin' during first-run setup."
fi
unset _origin_url _template_patterns

# ============================================================================
# NON-INTERACTIVE DETECTION
# ============================================================================
# Detect when running without a TTY (e.g., inside Claude Code or piped input).
# Scripts downstream use NON_INTERACTIVE to skip prompts and use defaults.

if [[ ! -t 0 ]]; then
    NON_INTERACTIVE=true
    export NON_INTERACTIVE
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

DRY_RUN_ONLY=false
RECONFIGURE_MCP=false
ROLLBACK_MODE=false
SKIP_PREFLIGHT=false
COMMON_ARGS=()
CONFIGURE_ARGS=()

# ============================================================================
# HELP TEXT
# ============================================================================

show_help() {
    cat << 'EOF'
install.sh - Claude Code Unified Installer

Single entry point for setting up Claude Code with cc-mirror.
Supports Debian/Ubuntu, Arch/SteamOS, Fedora/RHEL, and macOS.

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
  --skip-preflight   Skip pre-installation system checks
  --rollback         Restore from most recent backup (does not install)
  --help, -h         Show this help message

NOTES:
  - Phase 2 will prompt for MCP credentials (GitHub PAT, Jira token)
    during execution, not during preview
  - Both phases are idempotent (safe to re-run)
  - Phase 1 requires sudo for package installation (apt/pacman/dnf/brew)
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
        --skip-preflight)
            SKIP_PREFLIGHT=true
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

    # Prompt for confirmation (skip in non-interactive mode)
    if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
        if ! prompt_yes_no "Restore from most recent backup?" "n"; then
            echo ""
            log_info "Rollback cancelled by user."
            exit 0
        fi
    fi

    echo ""

    # Perform rollback
    rollback_last

    echo ""
    log_success "Rollback completed. Please verify your system state."
    exit 0
fi

# ============================================================================
# PREFLIGHT CHECKS
# ============================================================================

if [[ "${SKIP_PREFLIGHT}" != "true" ]]; then
    PREFLIGHT_SCRIPT="${SCRIPT_DIR}/preflight.sh"
    if [[ -f "${PREFLIGHT_SCRIPT}" ]]; then
        PREFLIGHT_ARGS=()
        [[ "${NO_COLOR:-false}" == "true" ]] && PREFLIGHT_ARGS+=(--no-color)
        if ! bash "${PREFLIGHT_SCRIPT}" "${PREFLIGHT_ARGS[@]+"${PREFLIGHT_ARGS[@]}"}"; then
            echo ""
            echo "Preflight checks failed. Fix the issues above, then re-run install.sh."
            echo "Or use --skip-preflight to bypass these checks."
            exit 1
        fi
        echo ""
    fi
fi

# ============================================================================
# PREVIEW
# ============================================================================

# Initialize logging (needed for log_warn/log_info to work under set -e)
log_init

print_header "Claude Code Setup - Preview"

echo "This installer will set up Claude Code in two phases."
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
echo "    5. Configure platform settings (git, credentials, shell RC)"
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
echo "  Phase 1 requires sudo for package installation."
echo "  Phase 2 will prompt for MCP credentials (GitHub PAT, etc.)."
echo ""

if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
    log_info "Non-interactive mode detected — proceeding automatically"
else
    if ! prompt_yes_no "Proceed with installation?" "y"; then
        echo ""
        log_info "Installation cancelled by user."
        exit 0
    fi
fi

echo ""

# ============================================================================
# PHASE 1: BASE SYSTEM
# ============================================================================

print_header "Phase 1: Base System Setup"

bash "${SCRIPT_DIR}/install-base.sh" "${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"}"

# Source bashrc to pick up nvm/node installed by Phase 1.
# This is needed because configure-claude.sh requires node and npm.
# nvm.sh uses unset variables internally, so relax strict mode during source.
export NVM_DIR="${HOME}/.nvm"
# shellcheck disable=SC1091
if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
    set +eu
    source "${NVM_DIR}/nvm.sh" 2>/dev/null
    set -eu
fi
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
# PHASE 3: DEPLOY GLOBAL CONFIG
# ============================================================================

print_header "Phase 3: Deploy Agent Fleet Configuration"

echo "Deploying global config, hooks, and knowledge files..."
bash "${CONFIG_REPO_ROOT}/sync.sh" setup

# Deploy afleet launcher (sync.sh setup already does this via deploy_afleet,
# but this is a safety fallback for first-run)
mkdir -p "${HOME}/.local/bin"
if [[ "${OSTYPE}" == msys* || "${OSTYPE}" == cygwin* ]]; then
    cp -f "${CONFIG_REPO_ROOT}/setup/scripts/afleet.sh" "${HOME}/.local/bin/afleet"
else
    ln -sf "${CONFIG_REPO_ROOT}/setup/scripts/afleet.sh" "${HOME}/.local/bin/afleet"
fi
log_info "Deployed: afleet → ~/.local/bin/"

# `af` is the standard fleet shortcut, not a personal alias (CFG-507). Install it for
# everyone — but never clobber an unrelated `af` that is already on PATH.
_af_target="${HOME}/.local/bin/af"
_af_existing="$(command -v af 2>/dev/null || true)"
if [[ -e "$_af_target" || -L "$_af_target" ]] || [[ -z "$_af_existing" ]]; then
    if [[ "${OSTYPE}" == msys* || "${OSTYPE}" == cygwin* ]]; then
        cp -f "${CONFIG_REPO_ROOT}/setup/scripts/afleet.sh" "$_af_target"
    else
        ln -sf "afleet" "$_af_target"
    fi
    log_info "Deployed: af → afleet (standard fleet shortcut)"
else
    log_warn "Skipped 'af' shortcut: an unrelated 'af' already exists at ${_af_existing}"
    log_warn "  Use 'afleet' instead, or remove that binary and re-run setup."
fi

# ============================================================================
# FINAL SUMMARY
# ============================================================================

print_header "Installation Complete!"

echo "All phases completed successfully."
echo ""
echo -e "${COLOR_BLUE}${COLOR_BOLD}To get started:${COLOR_RESET}"
_rc_name=$(detect_shell_rc_name 2>/dev/null || echo ".bashrc")
echo "  1. Open a new terminal (or run: source ~/${_rc_name})"
echo "  2. Run: afleet"
echo ""
echo -e "${COLOR_BLUE}Logs:${COLOR_RESET}"
echo "  Check ~/.claude-setup/logs/ for detailed logs"
echo ""
