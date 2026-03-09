#!/usr/bin/env bash
#
# plugin-inventory.sh — Scan installed plugin marketplaces and report status
# ===========================================================================
# Reports: marketplace directories, bundles/plugins per marketplace,
# token estimates, currently enabled plugins, global vs per-project status.
#
# Usage:
#   bash plugin-inventory.sh [--json]
#
# Environment:
#   PLUGIN_INV_CONFIG_DIR  Override config directory (for testing)

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

# Auto-detect config directory (override with PLUGIN_INV_CONFIG_DIR for testing)
if [[ -n "${PLUGIN_INV_CONFIG_DIR:-}" ]]; then
    CONFIG_DIR="$PLUGIN_INV_CONFIG_DIR"
else
    # Check for cc-mirror variant first, fall back to standard .claude directory
    CC_MIRROR_VARIANT="${CC_MIRROR_VARIANT:-mclaude}"
    if [[ -d "${HOME}/.cc-mirror/${CC_MIRROR_VARIANT}/config" ]]; then
        CONFIG_DIR="${HOME}/.cc-mirror/${CC_MIRROR_VARIANT}/config"
    else
        CONFIG_DIR="${HOME}/.claude"
    fi
fi

MARKETPLACES_DIR="${CONFIG_DIR}/plugins/marketplaces"
SETTINGS_FILE="${CONFIG_DIR}/settings.json"
JSON_MODE=false

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)  JSON_MODE=true; shift ;;
        --help|-h)
            echo "Usage: bash plugin-inventory.sh [--json]"
            echo ""
            echo "Scan installed plugin marketplaces and report status."
            echo ""
            echo "Options:"
            echo "  --json    Output as JSON (for programmatic use)"
            exit 0
            ;;
        *) shift ;;
    esac
done

# ============================================================================
# DATA COLLECTION
# ============================================================================

# Count marketplaces
marketplace_count=0
declare -a marketplace_names=()
declare -a marketplace_plugin_counts=()
declare -a marketplace_sizes=()

if [[ -d "$MARKETPLACES_DIR" ]]; then
    for mkt_dir in "$MARKETPLACES_DIR"/*/; do
        [[ -d "$mkt_dir" ]] || continue
        mkt_name=$(basename "$mkt_dir")
        marketplace_names+=("$mkt_name")
        ((marketplace_count++)) || true

        # Count plugins in this marketplace
        plugin_count=0
        total_size=0

        # Check external_plugins subdirectory
        ext_dir="$mkt_dir/external_plugins"
        if [[ -d "$ext_dir" ]]; then
            for plug_dir in "$ext_dir"/*/; do
                [[ -d "$plug_dir" ]] || continue
                ((plugin_count++)) || true
                # Get directory size in bytes
                dir_size=$(du -sb "$plug_dir" 2>/dev/null | cut -f1) || dir_size=0
                ((total_size += dir_size)) || true
            done
        fi

        # Check plugins subdirectory (built-in)
        builtin_dir="$mkt_dir/plugins"
        if [[ -d "$builtin_dir" ]]; then
            for plug_dir in "$builtin_dir"/*/; do
                [[ -d "$plug_dir" ]] || continue
                ((plugin_count++)) || true
                dir_size=$(du -sb "$plug_dir" 2>/dev/null | cut -f1) || dir_size=0
                ((total_size += dir_size)) || true
            done
        fi

        marketplace_plugin_counts+=("$plugin_count")
        marketplace_sizes+=("$total_size")
    done
fi

# Enabled plugins from settings.json
enabled_count=0
declare -a enabled_plugins=()
global_status="CLEAN"

if [[ -f "$SETTINGS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
    enabled_info=$(python3 -c "
import json, sys
try:
    settings = json.load(open('$SETTINGS_FILE'))
    ep = settings.get('enabledPlugins', {})
    print(len(ep))
    for k, v in ep.items():
        print(f'{k}={v}')
except Exception:
    print('0')
" 2>/dev/null) || enabled_info="0"

    # Parse output
    first_line=true
    while IFS= read -r line; do
        if $first_line; then
            enabled_count="$line"
            first_line=false
        else
            enabled_plugins+=("$line")
        fi
    done <<< "$enabled_info"

    if [[ "$enabled_count" -gt 0 ]]; then
        global_status="WARNING"
    fi
fi

# ============================================================================
# OUTPUT
# ============================================================================

if $JSON_MODE; then
    # Build JSON output
    # Marketplaces array
    mkt_json="["
    for i in "${!marketplace_names[@]}"; do
        [[ $i -gt 0 ]] && mkt_json+=","
        token_est=$(( ${marketplace_sizes[$i]} / 4 ))
        mkt_json+="{\"name\":\"${marketplace_names[$i]}\",\"plugins\":${marketplace_plugin_counts[$i]},\"size_bytes\":${marketplace_sizes[$i]},\"token_estimate\":$token_est}"
    done
    mkt_json+="]"

    # Enabled plugins array
    ep_json="["
    for i in "${!enabled_plugins[@]}"; do
        [[ $i -gt 0 ]] && ep_json+=","
        ep_json+="\"${enabled_plugins[$i]}\""
    done
    ep_json+="]"

    cat << EOF
{
  "config_dir": "$CONFIG_DIR",
  "marketplaces": $mkt_json,
  "marketplace_count": $marketplace_count,
  "enabled_plugins": $ep_json,
  "enabled_count": $enabled_count,
  "global_enablement": "$global_status"
}
EOF

else
    # Human-readable output
    echo "Plugin Inventory"
    echo "================"
    echo ""
    echo "Config: $CONFIG_DIR"
    echo ""

    echo "Marketplaces: $marketplace_count marketplace(s) found"
    if [[ $marketplace_count -gt 0 ]]; then
        for i in "${!marketplace_names[@]}"; do
            token_est=$(( ${marketplace_sizes[$i]} / 4 ))
            printf "  %-40s %d plugin(s), ~%d tokens\n" \
                "${marketplace_names[$i]}" \
                "${marketplace_plugin_counts[$i]}" \
                "$token_est"
        done
    fi
    echo ""

    echo "Enabled plugins: $enabled_count enabled plugin(s) in settings.json"
    if [[ $enabled_count -gt 0 ]]; then
        for ep in "${enabled_plugins[@]}"; do
            echo "  $ep"
        done
    fi
    echo ""

    echo "Global enablement: $global_status"
    if [[ "$global_status" == "WARNING" ]]; then
        echo "  enabledPlugins is non-empty in global settings.json!"
        echo "  Per policy, plugins should only be enabled per-project."
    fi
fi
