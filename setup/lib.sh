#!/usr/bin/env bash
#
# lib.sh - Shared utility library for Claude Code setup scripts
#
# This library provides logging, dry-run mode, backup/rollback, dependency
# checking, idempotency helpers, and argument parsing for installer scripts.
#
# Usage: source lib.sh
#

set -euo pipefail

# Guard against double-sourcing
[[ "${LIB_SH_LOADED:-}" == "true" ]] && return 0
readonly LIB_SH_LOADED="true"

# ============================================================================
# GLOBALS
# ============================================================================

DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
NO_COLOR="${NO_COLOR:-false}"
LOG_FILE=""
BACKUP_ROOT="${HOME}/.claude-setup/backups"
LOG_ROOT="${HOME}/.claude-setup/logs"
BACKUP_SESSION_ID=""

# ============================================================================
# COLOR DEFINITIONS
# ============================================================================

# Color codes (not readonly - log functions check NO_COLOR dynamically)
COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_BOLD='\033[1m'

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

# Initialize backup session ID
# Sets a shared timestamp for all backups in this session
backup_init() {
    BACKUP_SESSION_ID=$(date +%Y-%m-%d-%H%M%S)
}

# Initialize logging system
# Creates log directory and sets up tee to log file
log_init() {
    local timestamp
    timestamp=$(date +%Y-%m-%d-%H%M%S)
    mkdir -p "${LOG_ROOT}"
    LOG_FILE="${LOG_ROOT}/install-${timestamp}.log"

    # Write header to log file
    {
        echo "========================================"
        echo "Claude Code Setup - Log"
        echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "========================================"
        echo ""
    } > "${LOG_FILE}"

    # Initialize backup session for this run
    backup_init

    log_info "Logging initialized: ${LOG_FILE}"
}

# Strip ANSI color codes from string (portable — avoids sed regex issues on SteamOS)
_strip_ansi() {
    local text="$*"
    # Use tr to delete ESC characters, then sed for the bracket sequences
    # This two-step approach avoids \x1b escaping issues across sed versions
    printf '%s\n' "${text}" | tr -d '\033' | sed 's/\[[0-9;]*m//g'
}

# Get timestamp for log entries
_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Log info message (green)
log_info() {
    local msg="$*"
    if [[ "${NO_COLOR:-false}" == "true" ]]; then
        echo -e "[INFO] ${msg}"
    else
        echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} ${msg}"
    fi
    [[ -n "${LOG_FILE}" ]] && { _strip_ansi "[INFO] $(_timestamp) ${msg}" >> "${LOG_FILE}" 2>/dev/null || true; }
}

# Log warning message (yellow)
log_warn() {
    local msg="$*"
    if [[ "${NO_COLOR:-false}" == "true" ]]; then
        echo -e "[WARN] ${msg}" >&2
    else
        echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} ${msg}" >&2
    fi
    [[ -n "${LOG_FILE}" ]] && { _strip_ansi "[WARN] $(_timestamp) ${msg}" >> "${LOG_FILE}" 2>/dev/null || true; }
}

# Log error message (red)
log_error() {
    local msg="$*"
    if [[ "${NO_COLOR:-false}" == "true" ]]; then
        echo -e "[ERROR] ${msg}" >&2
    else
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} ${msg}" >&2
    fi
    [[ -n "${LOG_FILE}" ]] && { _strip_ansi "[ERROR] $(_timestamp) ${msg}" >> "${LOG_FILE}" 2>/dev/null || true; }
}

# Log success message (green, bold)
log_success() {
    local msg="$*"
    if [[ "${NO_COLOR:-false}" == "true" ]]; then
        echo -e "[SUCCESS] ${msg}"
    else
        echo -e "${COLOR_GREEN}${COLOR_BOLD}[SUCCESS]${COLOR_RESET} ${msg}"
    fi
    [[ -n "${LOG_FILE}" ]] && { _strip_ansi "[SUCCESS] $(_timestamp) ${msg}" >> "${LOG_FILE}" 2>/dev/null || true; }
}

# Print numbered step header
log_step() {
    local step="$1"
    local total="$2"
    local description="$3"
    local header="=== [${step}/${total}] ${description} ==="
    echo ""
    if [[ "${NO_COLOR:-false}" == "true" ]]; then
        echo -e "${header}"
    else
        echo -e "${COLOR_BLUE}${COLOR_BOLD}${header}${COLOR_RESET}"
    fi
    [[ -n "${LOG_FILE}" ]] && echo "" >> "${LOG_FILE}"
    [[ -n "${LOG_FILE}" ]] && echo "${header}" >> "${LOG_FILE}"
}

# ============================================================================
# DRY-RUN MODE
# ============================================================================

# Execute command or print dry-run message
run_cmd() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would execute: $*"
        [[ -n "${LOG_FILE}" ]] && echo "[DRY RUN] Would execute: $*" >> "${LOG_FILE}"
        return 0
    else
        if [[ "${VERBOSE}" == "true" ]]; then
            log_info "Executing: $*"
        fi
        "$@"
    fi
}

# Write file or print dry-run message
run_write() {
    local path="$1"
    local content="$2"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would write: ${path}"
        [[ -n "${LOG_FILE}" ]] && echo "[DRY RUN] Would write: ${path}" >> "${LOG_FILE}"
        return 0
    else
        printf '%s\n' "${content}" > "${path}"
        log_info "Wrote: ${path}"
    fi
}

# ============================================================================
# BACKUP AND ROLLBACK
# ============================================================================

# Backup a file before modifying
backup_file() {
    local src_path="$1"

    [[ ! -f "${src_path}" ]] && return 0  # Nothing to backup

    local timestamp
    if [[ -n "${BACKUP_SESSION_ID}" ]]; then
        timestamp="${BACKUP_SESSION_ID}"
    else
        timestamp=$(date +%Y-%m-%d-%H%M%S)
    fi
    local backup_dir="${BACKUP_ROOT}/${timestamp}"
    local relative_path="${src_path#/}"  # Remove leading slash
    local backup_path="${backup_dir}/${relative_path}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would backup: ${src_path} -> ${backup_path}"
        return 0
    fi

    mkdir -p "$(dirname "${backup_path}")"
    cp -a "${src_path}" "${backup_path}"
    log_info "Backed up: ${src_path} -> ${backup_path}"
}

# Backup a directory before modifying
backup_dir() {
    local src_path="$1"

    [[ ! -d "${src_path}" ]] && return 0  # Nothing to backup

    local timestamp
    if [[ -n "${BACKUP_SESSION_ID}" ]]; then
        timestamp="${BACKUP_SESSION_ID}"
    else
        timestamp=$(date +%Y-%m-%d-%H%M%S)
    fi
    local backup_dir="${BACKUP_ROOT}/${timestamp}"
    local relative_path="${src_path#/}"
    local backup_path="${backup_dir}/${relative_path}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would backup: ${src_path} -> ${backup_path}"
        return 0
    fi

    mkdir -p "$(dirname "${backup_path}")"
    cp -a "${src_path}" "${backup_path}"
    log_info "Backed up: ${src_path} -> ${backup_path}"
}

# Show available backup sets
rollback_show() {
    echo -e "${COLOR_BOLD}Available backup sets:${COLOR_RESET}"
    if [[ ! -d "${BACKUP_ROOT}" ]] || [[ -z "$(ls -A "${BACKUP_ROOT}" 2>/dev/null)" ]]; then
        echo "  (no backups found)"
        return 0
    fi

    for backup_set in "${BACKUP_ROOT}"/*; do
        [[ -d "${backup_set}" ]] || continue
        local timestamp
        timestamp=$(basename "${backup_set}")
        local file_count
        file_count=$(find "${backup_set}" -type f | wc -l)
        echo "  ${timestamp} (${file_count} files)"
    done
}

# Restore from most recent backup
rollback_last() {
    [[ ! -d "${BACKUP_ROOT}" ]] && { log_error "No backups found"; return 1; }

    local latest_backup
    latest_backup=$(ls -1t "${BACKUP_ROOT}" | head -n1)

    [[ -z "${latest_backup}" ]] && { log_error "No backups found"; return 1; }

    local backup_path="${BACKUP_ROOT}/${latest_backup}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${COLOR_YELLOW}[DRY RUN]${COLOR_RESET} Would restore from: ${backup_path}"
        return 0
    fi

    log_info "Restoring from backup: ${latest_backup}"

    # Restore all files from backup
    while IFS= read -r backup_file; do
        local relative_path="${backup_file#${backup_path}/}"
        local target_path="/${relative_path}"

        # Validate target falls within expected directories (defence-in-depth against
        # path traversal via crafted backup filenames containing ".." components)
        local allowed=false
        for allowed_prefix in "${HOME}/.claude/" "${HOME}/.cc-mirror/" "${HOME}/.claude-setup/"; do
            if [[ "${target_path}" == "${allowed_prefix}"* ]]; then
                allowed=true
                break
            fi
        done
        if [[ "${allowed}" != "true" ]]; then
            log_warn "Skipping backup file with unexpected target path: ${target_path}"
            continue
        fi

        mkdir -p "$(dirname "${target_path}")"
        cp -a "${backup_file}" "${target_path}"
        log_info "Restored: ${target_path}"
    done < <(find "${backup_path}" -type f)

    log_success "Rollback completed from ${latest_backup}"
}

# ============================================================================
# DEPENDENCY CHECKING
# ============================================================================

# Require command exists in PATH
require_cmd() {
    local cmd="$1"
    local hint="${2:-}"

    if ! command -v "${cmd}" &> /dev/null; then
        log_error "Required command not found: ${cmd}"
        [[ -n "${hint}" ]] && log_error "Install hint: ${hint}"
        exit 1
    fi

    [[ "${VERBOSE}" == "true" ]] && log_info "Found required command: ${cmd}"
}

# Require file exists
require_file() {
    local path="$1"
    local description="${2:-${path}}"

    if [[ ! -f "${path}" ]]; then
        log_error "Required file not found: ${description}"
        log_error "  Path: ${path}"
        exit 1
    fi

    [[ "${VERBOSE}" == "true" ]] && log_info "Found required file: ${description}"
}

# Require directory exists
require_dir() {
    local path="$1"
    local description="${2:-${path}}"

    if [[ ! -d "${path}" ]]; then
        log_error "Required directory not found: ${description}"
        log_error "  Path: ${path}"
        exit 1
    fi

    [[ "${VERBOSE}" == "true" ]] && log_info "Found required directory: ${description}"
}

# ============================================================================
# IDEMPOTENCY HELPERS
# ============================================================================

# Check if file contains pattern
file_contains() {
    local file="$1"
    local pattern="$2"

    [[ ! -f "${file}" ]] && return 1
    grep -qF "${pattern}" "${file}"
}

# Check if file exists and is non-empty
file_exists_nonempty() {
    local path="$1"
    [[ -f "${path}" ]] && [[ -s "${path}" ]]
}

# Check if two files are identical (by sha256 hash)
files_identical() {
    local file1="${1}" file2="${2}"
    [[ -f "${file1}" ]] && [[ -f "${file2}" ]] || return 1
    local hash_cmd="sha256sum"
    [[ "$(uname -s)" == "Darwin" ]] && hash_cmd="shasum -a 256"
    [[ "$($hash_cmd "${file1}" | cut -d' ' -f1)" == "$($hash_cmd "${file2}" | cut -d' ' -f1)" ]]
}

# ============================================================================
# DISTRO DETECTION
# ============================================================================

# Cached distro family
DETECTED_DISTRO=""

# Detect distro family from /etc/os-release
# Returns: debian, arch, fedora, or unknown
detect_distro() {
    if [[ -n "${DETECTED_DISTRO}" ]]; then
        echo "${DETECTED_DISTRO}"
        return
    fi
    if [[ "$(uname -s)" == "Darwin" ]]; then
        DETECTED_DISTRO="macos"
    elif [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian|linuxmint|pop) DETECTED_DISTRO="debian" ;;
            arch|steamos|endeavouros|manjaro) DETECTED_DISTRO="arch" ;;
            fedora|rhel|centos|rocky|alma) DETECTED_DISTRO="fedora" ;;
            *) DETECTED_DISTRO="unknown" ;;
        esac
    else
        DETECTED_DISTRO="unknown"
    fi
    echo "${DETECTED_DISTRO}"
}

# Check if running on SteamOS (Arch-based, immutable root FS)
is_steamos() {
    [[ -f /etc/os-release ]] && grep -qi 'steamos\|holo' /etc/os-release 2>/dev/null
}

# Check if running on WSL
is_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null
}

# Cross-distro package installed check
check_pkg_installed() {
    local pkg="$1"
    local distro
    distro=$(detect_distro)
    case "${distro}" in
        debian) dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed" ;;
        arch)
            # pacman -Qi doesn't work on package groups (e.g. base-devel).
            # Try individual package first, then check as group.
            pacman -Qi "${pkg}" &>/dev/null || { pacman -Sg "${pkg}" &>/dev/null && pacman -Qg "${pkg}" &>/dev/null; } ;;
        fedora) rpm -q "${pkg}" &>/dev/null ;;
        macos)  brew list --formula "${pkg}" &>/dev/null ;;
        *)      command -v "${pkg}" &>/dev/null ;;
    esac
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

# Parse common command-line arguments
parse_common_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                log_info "Dry-run mode enabled"
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --no-color)
                NO_COLOR=true
                shift
                ;;
            --help|-h)
                return 1  # Signal caller to show help
                ;;
            *)
                log_warn "Unknown argument: $1"
                shift
                ;;
        esac
    done
    return 0
}

# ============================================================================
# UI HELPERS
# ============================================================================

# Prompt user for yes/no confirmation
prompt_yes_no() {
    local prompt="${1}" default="${2:-n}"
    local response
    if [[ "${default}" == "y" ]]; then
        read -r -p "${prompt} [Y/n]: " response
        [[ "${response}" =~ ^[Nn] ]] && return 1 || return 0
    else
        read -r -p "${prompt} [y/N]: " response
        [[ "${response}" =~ ^[Yy] ]] && return 0 || return 1
    fi
}

# Print bold header
print_header() {
    local msg="$*"
    echo ""
    echo -e "${COLOR_BOLD}${COLOR_BLUE}========================================${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}${msg}${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}========================================${COLOR_RESET}"
    echo ""
}

# Print step indicator
print_step() {
    local msg="$*"
    echo -e "${COLOR_BLUE}▶${COLOR_RESET} ${msg}"
}

# Print success message
print_success() {
    local msg="$*"
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} ${msg}"
}

# Print warning message
print_warning() {
    local msg="$*"
    echo -e "${COLOR_YELLOW}⚠${COLOR_RESET} ${msg}"
}

# Print error message
print_error() {
    local msg="$*"
    echo -e "${COLOR_RED}✗${COLOR_RESET} ${msg}"
}
