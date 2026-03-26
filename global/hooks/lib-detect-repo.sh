#!/usr/bin/env bash
# lib-detect-repo.sh — Canonical config repo detection.
# Source from hooks and scripts. ONE source of truth for _detect_config_repo().
#
# Priority: $CONFIG_REPO env > caller symlink > .config-repo marker > sync.sh scan > fallback
# BASH_SOURCE[1] = the file that sourced this lib (the hook or script).

[[ "${_LIB_DETECT_REPO_LOADED:-}" == "true" ]] && return 0
_LIB_DETECT_REPO_LOADED="true"

# Ensure _readlink_f is available
source "$(dirname "${BASH_SOURCE[0]}")/lib-portable.sh" 2>/dev/null || true

_detect_config_repo() {
    # 1. Environment variable (set by settings.json env block or mclaude)
    if [[ -n "${CONFIG_REPO:-}" && -f "${CONFIG_REPO}/sync.sh" ]]; then
        echo "$CONFIG_REPO"
        return
    fi

    # 2. Caller's symlink resolution (dev: hooks run from within repo)
    local _caller="${BASH_SOURCE[1]:-}"
    if [[ -n "$_caller" ]]; then
        local _real
        _real="$(_readlink_f "$_caller" 2>/dev/null || echo "")"
        if [[ -n "$_real" && -f "$(dirname "$_real")/../../sync.sh" ]]; then
            echo "$(cd "$(dirname "$_real")/../.." && pwd)"
            return
        fi
    fi

    # 3. Scan: .config-repo marker has priority (positive signal)
    local d
    for d in "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [[ -f "$d/sync.sh" && -f "$d/.config-repo" ]] && echo "$d" && return
    done

    # 4. Scan: sync.sh present + no .template-repo (negative signal)
    for d in "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [[ -f "$d/sync.sh" && ! -f "$d/.template-repo" ]] && echo "$d" && return
    done

    # 5. Final fallback
    echo "$HOME/cfg-agent-fleet"
}
