#!/usr/bin/env bash
#
# clean-marketplace-plugins.sh — Remove unwanted external plugins from official marketplace
# ============================================================================================
# The official Claude Code marketplace auto-installs external plugins (MCP servers for
# third-party services like Asana, Stripe, Slack, etc). Most are useless — they require
# accounts/APIs we don't have, or they duplicate our own properly-configured MCP servers
# from ~/.mcp.json (with correct tokens, paths, env vars).
#
# This script removes unwanted plugins and keeps only the ones we actually use.
#
# Usage:
#   bash clean-marketplace-plugins.sh [--dry-run] [--verbose]
#
# Idempotent: safe to re-run. Only removes what exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source lib.sh if available
if [[ -f "${SCRIPT_DIR}/../lib.sh" ]]; then
    source "${SCRIPT_DIR}/../lib.sh"
else
    DRY_RUN="${DRY_RUN:-false}"
    log_info()    { echo "[INFO]  $*"; }
    log_success() { echo "[OK]    $*"; }
    log_warn()    { echo "[WARN]  $*"; }
    log_error()   { echo "[ERROR] $*" >&2; }
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

# Auto-detect config directory (override with CLEAN_PLUGINS_CONFIG_DIR for testing)
if [[ -n "${CLEAN_PLUGINS_CONFIG_DIR:-}" ]]; then
    CONFIG_DIR="$CLEAN_PLUGINS_CONFIG_DIR"
else
    CC_MIRROR_VARIANT="mclaude"
    if [[ -d "${HOME}/.cc-mirror/${CC_MIRROR_VARIANT}/config" ]]; then
        CONFIG_DIR="${HOME}/.cc-mirror/${CC_MIRROR_VARIANT}/config"
    else
        CONFIG_DIR="${HOME}/.claude"
    fi
fi

EXTERNAL_PLUGINS_DIR="${CONFIG_DIR}/plugins/marketplaces/claude-plugins-official/external_plugins"

# Plugins to KEEP — everything else gets removed.
# These are plugins we actively use or that are harmless/useful.
# Our own MCP servers are configured in ~/.mcp.json with proper tokens and paths,
# so marketplace duplicates (github, serena, playwright) should NOT be kept.
KEEP_PLUGINS=(
    "context7"
)

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

DRY_RUN="${DRY_RUN:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --verbose)  shift ;;
        --help|-h)
            echo "Usage: bash clean-marketplace-plugins.sh [--dry-run]"
            echo ""
            echo "Removes unwanted external plugins from the official Claude Code marketplace."
            echo "Keeps only: ${KEEP_PLUGINS[*]}"
            echo ""
            echo "Options:"
            echo "  --dry-run   Show what would be removed without doing it"
            exit 0
            ;;
        *) log_warn "Unknown argument: $1"; shift ;;
    esac
done

# ============================================================================
# MAIN
# ============================================================================

if [[ ! -d "$EXTERNAL_PLUGINS_DIR" ]]; then
    log_info "No external plugins directory found — nothing to clean"
    exit 0
fi

# Build newline-separated list for grep lookup (bash 3.2 compat — no declare -A)
_KEEP_LIST=$(printf '%s\n' "${KEEP_PLUGINS[@]}")

removed=0
kept=0
total=0

for plugin_dir in "$EXTERNAL_PLUGINS_DIR"/*/; do
    [[ -d "$plugin_dir" ]] || continue
    name=$(basename "$plugin_dir")
    ((total++)) || true

    if printf '%s\n' "$_KEEP_LIST" | grep -qxF "$name"; then
        ((kept++)) || true
        log_info "Keeping: $name"
        continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY RUN] Would remove: $name"
    else
        rm -rf "$plugin_dir"
        log_info "Removed: $name"
    fi
    ((removed++)) || true
done

if [[ $total -eq 0 ]]; then
    log_info "No external plugins found"
elif [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "[DRY RUN] Would remove $removed of $total plugins, keep $kept"
else
    log_success "Cleaned $removed of $total external plugins, kept $kept"
fi

# ============================================================================
# PHASE 2: Clean stale enabledPlugins from settings.json
# ============================================================================
# Plugins from non-existent marketplaces cause "N plugins failed to install" errors.
# The only marketplace we use is "claude-plugins-official". Any entry referencing
# another marketplace (e.g., "plugin@other-marketplace") is stale and should be removed.

SETTINGS_FILE="${CONFIG_DIR}/settings.json"
KNOWN_MARKETPLACE="claude-plugins-official"

if [[ -f "$SETTINGS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
    stale_count=$(python3 -c "
import json, sys
settings = json.load(open('$SETTINGS_FILE'))
ep = settings.get('enabledPlugins', {})
stale = [k for k in ep if '@' in k and k.split('@',1)[1] != '$KNOWN_MARKETPLACE']
print(len(stale))
" 2>/dev/null || echo "0")

    if [[ "$stale_count" -gt 0 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "[DRY RUN] Would remove $stale_count stale enabledPlugins entries from settings.json"
        else
            python3 -c "
import json
settings = json.load(open('$SETTINGS_FILE'))
ep = settings.get('enabledPlugins', {})
stale = [k for k in ep if '@' in k and k.split('@',1)[1] != '$KNOWN_MARKETPLACE']
for k in stale:
    del ep[k]
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
print(f'Removed {len(stale)} stale enabledPlugins entries')
" 2>/dev/null
            log_success "Cleaned $stale_count stale enabledPlugins entries from settings.json"
        fi
    fi
fi
