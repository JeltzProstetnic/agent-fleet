#!/usr/bin/env bash
# render-template.sh — Template variable rendering for agent-fleet config files (CFG-292)
#
# Replaces __DUNDER__ variables with runtime values and evaluates platform conditionals.
# Outputs rendered content to stdout. Does not modify the input file.
#
# Usage: bash render-template.sh [--vars-dir DIR] <template-file>
#
# Built-in variables (auto-detected):
#   __HOME__          — $HOME
#   __HOSTNAME__      — hostname (via get_hostname or $HOSTNAME)
#   __PLATFORM__      — wsl|linux|macos|windows (auto-detected)
#   __CONFIG_REPO__   — $CONFIG_REPO or auto-detected from script location
#   __CC_CONFIG_DIR__ — $CC_CONFIG_DIR or default cc-mirror path
#
# Machine vars override: --vars-dir DIR looks for <hostname>.vars
#   Format: KEY=value (one per line, no __DUNDER__ wrapping needed)
#
# Platform conditionals:
#   #__IF_PLATFORM_WSL__    — include block only on WSL
#   #__IF_PLATFORM_LINUX__  — include block only on native Linux
#   #__IF_PLATFORM_MACOS__  — include block only on macOS
#   #__ENDIF__              — end conditional block
#
# Unknown __DUNDER__ vars pass through unchanged (vault tokens, etc.)

set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────────────────

VARS_DIR=""
TEMPLATE_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vars-dir) VARS_DIR="$2"; shift 2 ;;
        -*)         echo "Unknown option: $1" >&2; exit 1 ;;
        *)          TEMPLATE_FILE="$1"; shift ;;
    esac
done

if [[ -z "$TEMPLATE_FILE" ]]; then
    echo "Usage: render-template.sh [--vars-dir DIR] <template-file>" >&2
    exit 1
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "Error: template file not found: $TEMPLATE_FILE" >&2
    exit 1
fi

# ── Detect platform ──────────────────────────────────────────────────────────

detect_platform() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
    elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        echo "windows"
    else
        echo "linux"
    fi
}

# ── Collect variables ────────────────────────────────────────────────────────

declare -A VARS

# Built-in defaults
VARS[HOME]="${HOME:-}"
VARS[HOSTNAME]="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
VARS[PLATFORM]="${PLATFORM:-$(detect_platform)}"
VARS[CONFIG_REPO]="${CONFIG_REPO:-}"
VARS[CC_CONFIG_DIR]="${CC_CONFIG_DIR:-${HOME}/.cc-mirror/mclaude/config}"

# Load machine-specific vars file (overrides defaults)
if [[ -n "$VARS_DIR" ]]; then
    local_hostname="${VARS[HOSTNAME]}"
    vars_file="$VARS_DIR/${local_hostname}.vars"
    if [[ -f "$vars_file" ]]; then
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            VARS[$key]="$value"
        done < "$vars_file"
    fi
fi

# ── Render ───────────────────────────────────────────────────────────────────

current_platform="${VARS[PLATFORM]}"
in_conditional=false
conditional_active=false

while IFS= read -r line || [[ -n "$line" ]]; do
    # Check for conditional start: #__IF_PLATFORM_XXX__
    if [[ "$line" =~ ^#__IF_PLATFORM_([A-Z]+)__$ ]]; then
        in_conditional=true
        target_platform="${BASH_REMATCH[1]}"
        # Case-insensitive compare
        if [[ "${target_platform,,}" == "${current_platform,,}" ]]; then
            conditional_active=true
        else
            conditional_active=false
        fi
        continue
    fi

    # Check for conditional end
    if [[ "$line" =~ ^#__ENDIF__$ ]]; then
        in_conditional=false
        conditional_active=false
        continue
    fi

    # Skip lines inside inactive conditional
    if $in_conditional && ! $conditional_active; then
        continue
    fi

    # Substitute known __DUNDER__ variables
    for key in "${!VARS[@]}"; do
        if [[ -n "${VARS[$key]}" ]]; then
            line="${line//__${key}__/${VARS[$key]}}"
        fi
    done

    printf '%s\n' "$line"
done < "$TEMPLATE_FILE"
