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
#   --skip-network          Skip network connectivity checks
#   --prerequisites-only    Run only the native Windows prerequisites (a no-op elsewhere)
#   --source-only           Define functions only (don't run checks)
#   --no-color              Disable colored output
#   --help, -h              Show this help message
#
# Exit codes:
#   0 - All required checks passed
#   1 - One or more required checks failed
#   3 - A native Windows prerequisite is missing (admin rights, PowerShell execution policy);
#       what is missing and the one thing to do were printed. Not bypassed by --skip-preflight.
#

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

PREFLIGHT_SKIP_NETWORK="${PREFLIGHT_SKIP_NETWORK:-false}"
PREFLIGHT_NO_COLOR="${NO_COLOR:-false}"
PREFLIGHT_SOURCE_ONLY=false
PREFLIGHT_PREREQ_ONLY=false
PREFLIGHT_HAS_FAILURES=false
PREFLIGHT_HAS_WARNINGS=false
PREFLIGHT_RC_PREREQ=3

# _is_native_windows (lib-portable.sh): OSTYPE msys/cygwin — Git Bash; WSL is Linux and never matches.
source "$(dirname "${BASH_SOURCE[0]}")/../global/hooks/lib-portable.sh" 2>/dev/null || true
type _is_native_windows >/dev/null 2>&1 || _is_native_windows() { [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; }

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

_pf_info() {
    echo -e "  ${_PF_BLUE}[INFO]${_PF_RESET} $*"
}

_pf_section() {
    echo ""
    echo -e "${_PF_BOLD}${_PF_BLUE}--- $* ---${_PF_RESET}"
    echo ""
}

# ============================================================================
# NATIVE WINDOWS PREREQUISITES — CFG-1087 (first, Git Bash only, no-op elsewhere)
# ============================================================================
# Decision 2026-11-20 (docs/decisions.md "Native Windows targets the public line"): admin rights and
# the PowerShell rights the fleet needs are PREREQUISITES — the installer checks and states them,
# nothing works around them; no non-admin path, no group-policy handling. So this never elevates
# and never changes a policy: it reads, states what is missing with the one thing the user does,
# and returns PREFLIGHT_RC_PREREQ (3). install.sh runs it even under --skip-preflight.

# powershell.exe without the user's profile; CRs stripped. Prints nothing when it cannot answer.
_pf_ps() {
    powershell.exe -NoProfile -NonInteractive -Command "$1" 2>/dev/null </dev/null | tr -d '\r'
}

# Elevated shell? `net session` answers only an elevated one (rc 0; otherwise "System error 5 …
# Access is denied"). When it cannot answer at all (Server service stopped), PowerShell's
# IsInRole(Administrator) — False under a UAC-filtered token — decides. Both read-only.
_pf_win_elevated() {
    if command -v net >/dev/null 2>&1 && net session >/dev/null 2>&1 </dev/null; then return 0; fi
    [[ "$(_pf_ps '([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)' | tail -1)" == True ]]
}

# "Scope=Policy" for each of the five scopes, then "Effective=<policy>"; nothing when PowerShell
# cannot answer. The fleet's .ps1 scripts are unsigned local scripts: RemoteSigned, Unrestricted or
# Bypass lets them run; Restricted (the Windows client default when every scope is Undefined) and
# AllSigned refuse them.
_pf_win_policy_lines() {
    _pf_ps 'Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }; "Effective=$(Get-ExecutionPolicy)"'
}

# States each scope; sets _pf_effective and _pf_gp (the Group Policy scopes that are set, if any).
_pf_win_state_policy() {
    local l
    _pf_effective="" _pf_gp=""
    while IFS= read -r l; do
        case "$l" in
            Effective=*) _pf_effective="${l#Effective=}" ;;
            MachinePolicy=Undefined|UserPolicy=Undefined) _pf_info "ExecutionPolicy ${l%%=*} = ${l#*=}" ;;
            MachinePolicy=*|UserPolicy=*) _pf_gp="${_pf_gp:+$_pf_gp, }${l%%=*}=${l#*=}"; _pf_info "ExecutionPolicy ${l%%=*} = ${l#*=} (set by Group Policy)" ;;
            *=*) _pf_info "ExecutionPolicy ${l%%=*} = ${l#*=}" ;;
        esac
    done <<< "$1"
}

check_windows_prerequisites() {
    _is_native_windows || return 0
    _pf_section "Native Windows prerequisites (CFG-1087)"
    local missing=0 elevated=no lines
    if _pf_win_elevated; then
        elevated=yes; _pf_pass "Administrator rights -- this shell is elevated"
    else
        _pf_fail "Administrator rights -- this shell is NOT elevated. Close it, start Git Bash with 'Run as administrator' (right-click its icon), re-run the installer there."
        missing=1
    fi
    lines=$(_pf_win_policy_lines) || true
    if [[ -z "$lines" ]]; then
        _pf_fail "PowerShell execution policy -- powershell.exe did not answer (Windows PowerShell 5.1 ships with Windows; is it on PATH?)"
        missing=1
    else
        _pf_win_state_policy "$lines"
        case "$_pf_effective" in
            RemoteSigned|Unrestricted|Bypass)
                _pf_pass "PowerShell execution policy -- effective $_pf_effective lets the fleet's .ps1 scripts run" ;;
            *)
                missing=1
                if [[ -n "$_pf_gp" ]]; then
                    _pf_fail "PowerShell execution policy -- effective ${_pf_effective:-unknown} is set by Group Policy ($_pf_gp); the installer does not change group policies. Have it set to RemoteSigned, then re-run the installer."
                else
                    _pf_fail "PowerShell execution policy -- effective ${_pf_effective:-unknown} refuses the fleet's .ps1 scripts. In PowerShell run:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned  then re-run the installer."
                fi ;;
        esac
    fi
    echo "  PREREQ: elevated=$elevated policy=${_pf_effective:-unknown} result=$([[ $missing -eq 0 ]] && echo ok || echo missing)"
    [[ $missing -eq 0 ]] || return "$PREFLIGHT_RC_PREREQ"
}

# ============================================================================
# CHECK FUNCTIONS
# ============================================================================

# Check required and recommended commands
# Required: git (must be pre-installed)
# Installer-handled: node, npm (installed by install-base.sh via NVM)
# Recommended: python3/python, curl, jq
check_commands() {
    _pf_section "Commands"

    local required_cmds=("git")
    local installer_cmds=("node" "npm")
    local recommended_cmds=("curl" "jq")

    # Required commands (must exist before install)
    for cmd in "${required_cmds[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            local version
            version=$("$cmd" --version 2>/dev/null | head -n1 || echo "unknown")
            _pf_pass "$cmd (required) -- $version"
        else
            _pf_fail "$cmd (required) -- not found"
        fi
    done

    # Installer-handled commands (nice to have, installed if missing)
    for cmd in "${installer_cmds[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            local version
            version=$("$cmd" --version 2>/dev/null | head -n1 || echo "unknown")
            _pf_pass "$cmd (will be managed by installer) -- $version"
        else
            _pf_info "$cmd -- not found (will be installed by setup)"
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

    # Native Windows prerequisites come first and end the run (exit 3) when one is missing.
    check_windows_prerequisites || return $?

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
            --prerequisites-only)
                PREFLIGHT_PREREQ_ONLY=true
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
                echo "Usage: bash preflight.sh [--skip-network] [--prerequisites-only] [--source-only] [--no-color]"
                echo ""
                echo "Options:"
                echo "  --skip-network         Skip network connectivity checks"
                echo "  --prerequisites-only   Only the native Windows prerequisites (admin, execution policy); no-op elsewhere"
                echo "  --source-only          Define functions only (don't run checks)"
                echo "  --no-color             Disable colored output"
                echo "  --help, -h             Show this help message"
                echo ""
                echo "Exit codes: 0 passed, 1 a check failed, 3 a native Windows prerequisite is missing"
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
    if [[ "${PREFLIGHT_PREREQ_ONLY}" == "true" ]]; then
        check_windows_prerequisites || exit $?
        exit 0
    fi
    run_preflight
fi
