#!/usr/bin/env bash
# SessionStart hook: check for config sync failures, symlink health, and inbox tasks.
# Outputs JSON with systemMessage so Claude sees the warning in context.
#
# Check modules live in checks/ subdirectory (01-sync-state.sh through 14-audit-staleness.sh).
# Each module reads/modifies the shared variables below.

# Source portable wrappers (provides _readlink_f for macOS compat)
source "$(dirname "${BASH_SOURCE[0]}")/lib-portable.sh" 2>/dev/null || true

# Auto-detect config repo: try symlink source, then known paths
_detect_config_repo() {
    local hook_real
    hook_real="$(_readlink_f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")"
    if [[ -n "$hook_real" && -f "$(dirname "$hook_real")/../../sync.sh" ]]; then
        echo "$(cd "$(dirname "$hook_real")/../.." && pwd)"
        return
    fi
    for d in "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [[ -f "$d/sync.sh" && ! -f "$d/.template-repo" ]] && echo "$d" && return
    done
    echo "$HOME/cfg-agent-fleet"  # final fallback
}

# ── Shared state (used by all check modules) ──
CONFIG_REPO="$(_detect_config_repo)"
FAIL_MARKER="$CONFIG_REPO/.sync-failed"
WARNINGS=""
INBOX_MSG=""

DEFAULT_BRANCH=$(git -C "$CONFIG_REPO" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

CC_MIRROR_DIR="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}"
SETTINGS_FILE="$CC_MIRROR_DIR/config/settings.json"
PROJECT_DIR="$(pwd)"
PROJECT_ROOT="$(git -C "$CONFIG_REPO" rev-parse --show-toplevel 2>/dev/null || echo "$CONFIG_REPO")"

# ── Resolve checks directory ──
_HOOK_DIR="$(cd "$(dirname "$(_readlink_f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
_CHECKS_DIR="${CONFIG_CHECK_DIR:-${_HOOK_DIR}/checks}"

# ── Source and execute check modules (alphabetical order) ──
if [ -d "$_CHECKS_DIR" ]; then
    for _check_file in "$_CHECKS_DIR"/*.sh; do
        [ -f "$_check_file" ] || continue
        source "$_check_file" 2>/dev/null || true
    done
fi

# ── Output JSON ──
SYSTEM_MSG=""
if [ -n "$WARNINGS" ]; then
    SYSTEM_MSG="WARNING: $(printf '%s' "$WARNINGS" | tr '\n' ' ') Tell the user about this issue immediately before doing any other work."
fi
if [ -n "$INBOX_MSG" ]; then
    SYSTEM_MSG="${SYSTEM_MSG:+$SYSTEM_MSG | }$(printf '%s' "$INBOX_MSG" | tr '\n' ' ')"
fi

if [ -n "$SYSTEM_MSG" ]; then
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json,sys; print(json.dumps({'systemMessage': sys.argv[1]}))" "$SYSTEM_MSG"
    elif command -v node >/dev/null 2>&1; then
        node -e "console.log(JSON.stringify({systemMessage: process.argv[1]}))" "$SYSTEM_MSG"
    fi
fi

exit 0
