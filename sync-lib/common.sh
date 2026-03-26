#!/usr/bin/env bash
# sync-lib/common.sh — Shared utility functions for sync.sh modules
#
# Expects these variables from the caller:
#   SCRIPT_DIR, GLOBAL_DIR, PROJECTS_DIR, CLAUDE_HOME, PLATFORM
#   RED, GREEN, YELLOW, NC
#   log_info, log_warn, log_error (functions)

# Source portable wrappers (_sed_i, _readlink_f, etc.)
source "${GLOBAL_DIR:-$SCRIPT_DIR/global}/hooks/lib-portable.sh" 2>/dev/null || true

# cc-mirror root (Claude Code installed via cc-mirror)
CC_MIRROR_DIR="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}"

# ---- Portable hostname (SteamOS has no hostname binary) ----
get_hostname() {
    hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo "unknown"
}

# ---- Find project path by name ----
find_project_path() {
    local name="$1"
    # Check common locations
    for candidate in "$HOME/$name" "$HOME/projects/$name"; do
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    # Check registry for custom paths
    if [ -f "$SCRIPT_DIR/registry.md" ]; then
        local path
        path=$(grep -F "| $name |" "$SCRIPT_DIR/registry.md" 2>/dev/null | head -1 | awk -F'|' '{print $4}' | xargs | tr -d '`')
        if [ -n "$path" ]; then
            path="${path/#\~/$HOME}"
            if [ -d "$path" ]; then
                echo "$path"
            fi
        fi
    fi
}

# ---- Extract file|hash pairs from a named manifest section ----
# Usage: _extract_manifest_section "Must Be Identical" "$manifest_file"
# Returns lines like: path|hash
_extract_manifest_section() {
    local section_name="$1"
    local manifest_file="$2"
    awk -v section="$section_name" '
        $0 ~ "## Tracked Files.*" section { in_section=1; next }
        /^## / && in_section { in_section=0 }
        in_section && /^\| `[^`]+` \| `[0-9a-f]{8}`/ { print }
    ' "$manifest_file" | sed 's/^| `//;s/` | `/|/;s/`.*$//' || true
}
