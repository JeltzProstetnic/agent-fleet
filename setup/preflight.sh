#!/usr/bin/env bash
#
# preflight.sh - Pre-installation system check
# ==============================================
# Verifies that the system meets requirements before running install.sh.
# Can be sourced (--source-only) for individual function access.
#
# Usage:
#   bash preflight.sh [options]
#
# Options:
#   --skip-network   Skip network connectivity checks
#   --source-only    Define functions only (don't run checks)
#   --no-color       Disable colored output
#   --help, -h       Show this help message
#
# Exit codes:
#   0 - All required checks passed
#   1 - One or more required checks failed
#

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

PREFLIGHT_SKIP_NETWORK="${PREFLIGHT_SKIP_NETWORK:-false}"
PREFLIGHT_NO_COLOR="${NO_COLOR:-false}"
PREFLIGHT_SOURCE_ONLY=false
PREFLIGHT_HAS_FAILURES=false
PREFLIGHT_HAS_WARNINGS=false

# Colors
if [[ "${PREFLIGHT_NO_COLOR}" != "true" ]]; then
    _PF_RED='\033[0;31m'
    _PF_GREEN='\033[0;32m'
    _PF_YELLOW='\033[0;33m'
    _PF_BLUE='\033[0;34m'
    _PF_BOLD='\033[1m'
    _PF_RESET='\033[0m'
else
    _PF_RED='' _PF_GREEN='' _PF_YELLOW='' _PF_BLUE='' _PF_BOLD='' _PF_RESET=''
fi

# ============================================================================
# OUTPUT HELPERS
# ============================================================================

_pf_pass() {
    echo -e "  ${_PF_GREEN}[PASS]${_PF_RESET} $*"
}

_pf_fail() {
    echo -e "  ${_PF_RED}[FAIL]${_PF_RESET} $*"
    PREFLIGHT_HAS_FAILURES=true
}

_pf_warn() {
    echo -e "  ${_PF_YELLOW}[WARN]${_PF_RESET} $*"
    PREFLIGHT_HAS_WARNINGS=true
}

_pf_section() {
    echo ""
    echo -e "${_PF_BOLD}${_PF_BLUE}--- $* ---${_PF_RESET}"
    echo ""
}

# ============================================================================
# CHECK FUNCTIONS
# ============================================================================

# Check required and recommended commands
# Required: git, node, npm
# Recommended: python3/python, curl, jq
check_commands() {
    _pf_section "Commands"

    local required_cmds=("git" "node" "npm")
    local recommended_cmds=("curl" "jq")

    # Required commands
    for cmd in "${required_cmds[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            local version
            version=$("$cmd" --version 2>/dev/null | head -n1 || echo "unknown")
            _pf_pass "$cmd (required) -- $version"
        else
            _pf_fail "$cmd (required) -- not found"
        fi
    done

    # Python is special — accept python3 or python
    if command -v python3 &>/dev/null; then
        local version
        version=$(python3 --version 2>/dev/null || echo "unknown")
        _pf_pass "python3 (required) -- $version"
    elif command -v python &>/dev/null; then
        local version
        version=$(python --version 2>/dev/null || echo "unknown")
        _pf_pass "python (required, via python alias) -- $version"
    else
        _pf_fail "python3 (required) -- not found (neither python3 nor python)"
    fi

    # Recommended commands
    for cmd in "${recommended_cmds[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            local version
            version=$("$cmd" --version 2>/dev/null | head -n1 || echo "unknown")
            _pf_pass "$cmd (recommended) -- $version"
        else
            _pf_warn "$cmd (recommended) -- not found"
        fi
    done
}

# Check writable paths
check_paths() {
    _pf_section "Paths"

    # HOME must be writable
    if [[ -w "${HOME}" ]]; then
        _pf_pass "\$HOME (${HOME}) is writable"
    else
        _pf_fail "\$HOME (${HOME}) is not writable"
    fi

    # ~/.local/bin — create if missing
    local local_bin="${HOME}/.local/bin"
    if [[ -d "${local_bin}" ]]; then
        if [[ -w "${local_bin}" ]]; then
            _pf_pass "~/.local/bin exists and is writable"
        else
            _pf_fail "~/.local/bin exists but is not writable"
        fi
    else
        mkdir -p "${local_bin}" 2>/dev/null && {
            _pf_pass "~/.local/bin created successfully"
        } || {
            _pf_fail "~/.local/bin does not exist and could not be created"
        }
    fi
}

# Check network connectivity
check_network() {
    if [[ "${PREFLIGHT_SKIP_NETWORK}" == "true" ]]; then
        return 0
    fi

    _pf_section "Network"

    # github.com
    if curl -sf --connect-timeout 5 --max-time 5 "https://github.com" >/dev/null 2>&1; then
        _pf_pass "github.com (port 443) -- reachable"
    else
        _pf_warn "github.com (port 443) -- not reachable (5s timeout)"
    fi

    # registry.npmjs.org
    if curl -sf --connect-timeout 5 --max-time 5 "https://registry.npmjs.org/" >/dev/null 2>&1; then
        _pf_pass "registry.npmjs.org -- reachable"
    else
        _pf_warn "registry.npmjs.org -- not reachable (5s timeout)"
    fi
}

# Check disk space (>1GB free in HOME)
check_disk_space() {
    _pf_section "Disk space"

    local free_kb
    # df -P for POSIX output, awk to get available KB for HOME mount
    free_kb=$(df -Pk "${HOME}" 2>/dev/null | tail -n1 | awk '{print $4}')

    if [[ -z "${free_kb}" ]]; then
        _pf_warn "Disk space -- could not determine free space"
        return 0
    fi

    local free_mb=$((free_kb / 1024))
    local free_gb=$((free_mb / 1024))

    if [[ ${free_mb} -ge 1024 ]]; then
        _pf_pass "Disk space in \$HOME -- ${free_gb}GB free (>1GB required)"
    else
        _pf_fail "Disk space in \$HOME -- ${free_mb}MB free (<1GB, need at least 1GB)"
    fi
}

# ============================================================================
# MAIN — RUN ALL CHECKS
# ============================================================================

run_preflight() {
    echo -e "${_PF_BOLD}Preflight System Check${_PF_RESET}"
    echo "Checking system requirements for Claude Code installation..."

    check_commands
    check_paths
    check_network
    check_disk_space

    # Summary
    echo ""
    echo -e "${_PF_BOLD}--- Summary ---${_PF_RESET}"
    echo ""

    if [[ "${PREFLIGHT_HAS_FAILURES}" == "true" ]]; then
        echo -e "  ${_PF_RED}Some required checks failed.${_PF_RESET} Fix the [FAIL] items above before installing."
        return 1
    elif [[ "${PREFLIGHT_HAS_WARNINGS}" == "true" ]]; then
        echo -e "  ${_PF_YELLOW}All required checks passed, but some recommended items are missing.${_PF_RESET}"
        echo "  Installation can proceed, but some features may be limited."
        return 0
    else
        echo -e "  ${_PF_GREEN}All checks passed.${_PF_RESET} Ready to install."
        return 0
    fi
}

# ============================================================================
# ARGUMENT PARSING & ENTRY POINT
# ============================================================================

_preflight_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-network)
                PREFLIGHT_SKIP_NETWORK=true
                shift
                ;;
            --source-only)
                PREFLIGHT_SOURCE_ONLY=true
                shift
                ;;
            --no-color)
                PREFLIGHT_NO_COLOR=true
                _PF_RED='' _PF_GREEN='' _PF_YELLOW='' _PF_BLUE='' _PF_BOLD='' _PF_RESET=''
                shift
                ;;
            --help|-h)
                echo "preflight.sh - Pre-installation system check"
                echo ""
                echo "Usage: bash preflight.sh [--skip-network] [--source-only] [--no-color]"
                echo ""
                echo "Options:"
                echo "  --skip-network   Skip network connectivity checks"
                echo "  --source-only    Define functions only (don't run checks)"
                echo "  --no-color       Disable colored output"
                echo "  --help, -h       Show this help message"
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done
}

# Parse args
_preflight_parse_args "$@"

# If sourced with --source-only, just define functions and exit
if [[ "${PREFLIGHT_SOURCE_ONLY}" == "true" ]]; then
    return 0 2>/dev/null || true
fi

# Run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_preflight
fi
