#!/usr/bin/env bash
# SessionStart hook: check for config sync failures, symlink health, and inbox tasks.
# Outputs JSON with systemMessage so Claude sees the warning in context.

# Auto-detect config repo: try symlink source, then known paths
_detect_config_repo() {
    local hook_real
    hook_real="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")"
    if [[ -n "$hook_real" && -f "$(dirname "$hook_real")/../../sync.sh" ]]; then
        cd "$(dirname "$hook_real")/../.." && pwd
        return
    fi
    for d in "$HOME/agent-fleet" "$HOME/cfg-agent-fleet"; do
        [[ -f "$d/sync.sh" ]] && echo "$d" && return
    done
    echo "$HOME/agent-fleet"  # final fallback
}
CONFIG_REPO="$(_detect_config_repo)"
FAIL_MARKER="$CONFIG_REPO/.sync-failed"
WARNINGS=""

# Auto-detect default branch
DEFAULT_BRANCH=$(git -C "$CONFIG_REPO" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

# Check 1: Did the last auto-sync fail?
if [ -f "$FAIL_MARKER" ]; then
    stage=$(grep '^stage=' "$FAIL_MARKER" | cut -d= -f2)
    time=$(grep '^time=' "$FAIL_MARKER" | cut -d= -f2-)
    detail=$(grep '^detail=' "$FAIL_MARKER" | cut -d= -f2-)
    WARNINGS="CONFIG SYNC FAILED at $time — stage: $stage, detail: $detail. Run 'bash $CONFIG_REPO/sync.sh status' to diagnose. Uncommitted config changes may exist in $CONFIG_REPO/."
fi

# Check 2: Are symlinks intact?
if [ ! -L "$HOME/.claude/CLAUDE.md" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }CLAUDE.md is not symlinked to config repo. Run 'bash $CONFIG_REPO/sync.sh setup' to restore."
fi

# Check 3: Does config repo exist?
if [ ! -d "$CONFIG_REPO/.git" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }Config repo not found at $CONFIG_REPO/. Clone your config repo and run: bash $CONFIG_REPO/sync.sh setup"
fi

# Check 4: Pull latest config (so inbox is current), and report changed files
if [ -d "$CONFIG_REPO/.git" ]; then
    OLD_HEAD=$(git -C "$CONFIG_REPO" rev-parse HEAD 2>/dev/null || true)
    git -C "$CONFIG_REPO" pull --ff-only origin "$DEFAULT_BRANCH" 2>/dev/null || true
    NEW_HEAD=$(git -C "$CONFIG_REPO" rev-parse HEAD 2>/dev/null || true)
    if [ -n "$OLD_HEAD" ] && [ -n "$NEW_HEAD" ] && [ "$OLD_HEAD" != "$NEW_HEAD" ]; then
        CHANGED_FILES=$(git -C "$CONFIG_REPO" diff --name-only "$OLD_HEAD".."$NEW_HEAD" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
        if [ -n "$CHANGED_FILES" ]; then
            WARNINGS="${WARNINGS:+$WARNINGS | }Config updated from remote: $CHANGED_FILES changed — re-read these files before proceeding."
        fi
    fi
fi

# Check 5: Detect unclean shutdown — session-context.md has content but wasn't rotated
# If session-context.md has a Session Goal filled in, it means the previous session's
# auto-rotate either failed or the session had too little content to archive.
# Either way, the next session should know about it.
PROJECT_DIR="$(pwd)"
if [[ -f "$PROJECT_DIR/session-context.md" && -s "$PROJECT_DIR/session-context.md" ]]; then
    PREV_GOAL=$(sed -n 's/.*\*\*Session Goal\*\*: \(.\+\)/\1/p' "$PROJECT_DIR/session-context.md" 2>/dev/null | head -1)
    if [[ -n "$PREV_GOAL" ]]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }Previous session may have ended unexpectedly (session-context.md still has content from goal: '$PREV_GOAL'). Review it and decide whether to continue that work or start fresh. If continuing, read session-context.md for recovery instructions. If starting fresh, the old state will be preserved in session-history.md after rotation."
    fi
fi

# Check 6: Cross-project inbox — surface pending tasks for current project
INBOX="$CONFIG_REPO/cross-project/inbox.md"
INBOX_MSG=""
if [ -f "$INBOX" ]; then
    PROJECT_NAME=$(basename "$(pwd)")
    TASKS=$(grep -i "\- \[ \].*\*\*$PROJECT_NAME\*\*" "$INBOX" 2>/dev/null || true)
    if [ -n "$TASKS" ]; then
        INBOX_MSG="INBOX TASKS for $PROJECT_NAME: $TASKS"
    fi
    TOTAL=$(grep -c '\- \[ \]' "$INBOX" 2>/dev/null || echo "0")
    if [ "$TOTAL" -gt 0 ]; then
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }Cross-project inbox has $TOTAL pending task(s). Read $CONFIG_REPO/cross-project/inbox.md"
    fi
fi

# Check 7: Detect unmerged branches (mobile sessions create branches, not commits to main)
if [ -d "$CONFIG_REPO/.git" ]; then
    UNMERGED=$(git -C "$CONFIG_REPO" branch -r --no-merged "$DEFAULT_BRANCH" 2>/dev/null | grep -v HEAD | sed 's/^ *//' | tr '\n' ', ' | sed 's/, $//')
    if [ -n "$UNMERGED" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }Unmerged branches detected: $UNMERGED — mobile sessions work in branches. Review and cherry-pick useful commits, then delete the branch."
    fi
fi

# Output JSON if there are warnings or inbox items
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
