#!/usr/bin/env bash
# Auto-sync cfg-agent-fleet repo on session end.
# Runs as a SessionEnd hook — silent, zero context cost.
#
# NOTE: This hook always operates on ~/cfg-agent-fleet/, NOT the current project.
# It collects project rules, commits cfg-agent-fleet changes, and pushes.
# Dual-remote projects are not affected — this hook doesn't push them.
#
# On failure: writes a marker to ~/cfg-agent-fleet/.sync-failed
# The SessionStart hook (config-check.sh) reads this marker and alerts the user.

CONFIG_REPO="$HOME/cfg-agent-fleet"
FAIL_MARKER="$CONFIG_REPO/.sync-failed"

# Clear any previous failure marker on success path
sync_success() {
    rm -f "$FAIL_MARKER"
    exit 0
}

sync_fail() {
    local stage="$1" detail="$2"
    printf 'stage=%s\ntime=%s\ndetail=%s\n' "$stage" "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" "$detail" > "$FAIL_MARKER"
    exit 0  # Still exit 0 — don't block session end
}

cd "$CONFIG_REPO" 2>/dev/null || sync_fail "cd" "Config repo not found at $CONFIG_REPO"

# Collect project-specific rules
bash "$CONFIG_REPO/sync.sh" collect 2>/dev/null || sync_fail "collect" "sync.sh collect failed"

# Stage tracked changes + new files in key directories
git add -u 2>/dev/null
git add session-context.md session-history.md docs/ projects/ cross-project/ 2>/dev/null || true
git diff --cached --quiet 2>/dev/null && sync_success  # Nothing to sync

# Commit
git commit -m "Auto-sync: $(date -u +'%Y-%m-%d %H:%M:%S UTC')" 2>/dev/null \
    || sync_fail "commit" "git commit failed"

# Push (auto-detect default branch: main or master)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"
git push origin "$DEFAULT_BRANCH" 2>/dev/null \
    || sync_fail "push" "git push failed (network? auth?)"

sync_success
