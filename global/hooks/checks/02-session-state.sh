#!/usr/bin/env bash
# Check group 2: Session state — pull latest config, detect unclean shutdown
# Checks: 2.1, 2.2
# Shared vars used: CONFIG_REPO, WARNINGS, DEFAULT_BRANCH, PROJECT_DIR

# Check 2.1: Pull latest config (so inbox is current), and report changed files
if [ -d "$CONFIG_REPO/.git" ]; then
    SYNC_REMOTE="origin"
    if [ -f "$CONFIG_REPO/.push-filter.conf" ]; then
        PR=$(grep '^private_remote=' "$CONFIG_REPO/.push-filter.conf" 2>/dev/null | head -1 | cut -d= -f2 | xargs)
        [ -n "$PR" ] && SYNC_REMOTE="$PR"
    fi
    OLD_HEAD=$(git -C "$CONFIG_REPO" rev-parse HEAD 2>/dev/null || true)
    # CFG-503: BOTH streams must be silenced. `git pull` writes "Already up to
    # date." to STDOUT, and this hook's stdout is a JSON contract — any stray
    # byte makes CC discard the entire additionalContext payload, so every
    # SessionStart check goes dark with no error anywhere. Never `2>/dev/null`
    # alone on a command run inside a hook that prints JSON.
    if ! git -C "$CONFIG_REPO" pull --ff-only "$SYNC_REMOTE" "$DEFAULT_BRANCH" >/dev/null 2>&1; then
        WARNINGS="${WARNINGS:+$WARNINGS | }Config repo could not fast-forward — branches may have diverged"
    fi
    NEW_HEAD=$(git -C "$CONFIG_REPO" rev-parse HEAD 2>/dev/null || true)
    if [ -n "$OLD_HEAD" ] && [ -n "$NEW_HEAD" ] && [ "$OLD_HEAD" != "$NEW_HEAD" ]; then
        CHANGED_FILES=$(git -C "$CONFIG_REPO" diff --name-only "$OLD_HEAD".."$NEW_HEAD" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
        if [ -n "$CHANGED_FILES" ]; then
            WARNINGS="${WARNINGS:+$WARNINGS | }Config updated from remote: $CHANGED_FILES changed — re-read these files before proceeding."
        fi
    fi
fi

# Check 2.2: Detect unclean shutdown — session-context.md has content but wasn't rotated
if [[ -f "$PROJECT_DIR/session-context.md" && -s "$PROJECT_DIR/session-context.md" ]]; then
    PREV_GOAL=$(sed -n 's/.*\*\*Session Goal\*\*: \(.\+\)/\1/p' "$PROJECT_DIR/session-context.md" 2>/dev/null | head -1)
    if [[ -n "$PREV_GOAL" ]]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }Previous session may have ended unexpectedly (session-context.md still has content from goal: '$PREV_GOAL'). Review it and decide whether to continue that work or start fresh. If continuing, read session-context.md for recovery instructions. If starting fresh, the old state will be preserved in session-history.md after rotation."
    fi
fi
