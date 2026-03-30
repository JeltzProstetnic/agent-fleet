#!/usr/bin/env bash
# SessionStart hook: check for config sync failures, symlink health, and inbox tasks.
# Outputs JSON with additionalContext so Claude sees the warning in context (invisible to user).
#
# Check modules live in checks/ subdirectory (01-sync-state.sh through 14-audit-staleness.sh).
# Each module reads/modifies the shared variables below.

# Source portable wrappers (provides _readlink_f for macOS compat)
source "$(dirname "${BASH_SOURCE[0]}")/lib-portable.sh" 2>/dev/null || true

# Config repo detection — canonical source in lib-detect-repo.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-detect-repo.sh" 2>/dev/null || true

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

# ── First-run mode: suppress non-critical checks when .setup-pending exists ──
FIRST_RUN_MODE=0
if [ -f "$PROJECT_ROOT/.setup-pending" ] || [ -f "$CONFIG_REPO/.setup-pending" ]; then
    FIRST_RUN_MODE=1
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }[INFO] First-run mode — skipping non-essential checks (.setup-pending detected)"
fi

# ── Source and execute check modules (alphabetical order) ──
if [ -d "$_CHECKS_DIR" ]; then
    for _check_file in "$_CHECKS_DIR"/*.sh; do
        [ -f "$_check_file" ] || continue
        # In first-run mode, only load critical checks
        if [ "$FIRST_RUN_MODE" -eq 1 ]; then
            _check_basename="$(basename "$_check_file")"
            case "$_check_basename" in
                01-sync-state.sh|04-auto-fix.sh|06a-session-state.sh) ;;
                *) continue ;;
            esac
        fi
        source "$_check_file" 2>/dev/null || true
    done
fi

# ── Output JSON ──
SYSTEM_MSG=""
if [ -n "$WARNINGS" ]; then
    if [ "$FIRST_RUN_MODE" -eq 1 ]; then
        SYSTEM_MSG="$(printf '%s' "$WARNINGS" | tr '\n' ' ')"
    else
        SYSTEM_MSG="WARNING: $(printf '%s' "$WARNINGS" | tr '\n' ' ') Tell the user about this issue immediately before doing any other work."
    fi
fi
if [ -n "$INBOX_MSG" ]; then
    SYSTEM_MSG="${SYSTEM_MSG:+$SYSTEM_MSG | }$(printf '%s' "$INBOX_MSG" | tr '\n' ' ')"
fi

if [ -n "$SYSTEM_MSG" ]; then
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json,sys; print(json.dumps({'additionalContext': sys.argv[1]}))" "$SYSTEM_MSG"
    elif command -v node >/dev/null 2>&1; then
        node -e "console.log(JSON.stringify({additionalContext: process.argv[1]}))" "$SYSTEM_MSG"
    fi
fi

exit 0
