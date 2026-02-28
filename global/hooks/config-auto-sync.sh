#!/usr/bin/env bash
# Auto-sync config repo on session end.
# Runs as a SessionEnd hook — silent, zero context cost.
#
# What this hook does (in order):
# 1. Auto-rotate the CURRENT PROJECT's session (if it has session-context.md)
# 2. Commit session files in current project (if different from config repo)
# 3. Auto-rotate config repo's own session
# 4. Collect project rules, commit config repo changes, and push
#
# On failure: writes a marker to .sync-failed
# The SessionStart hook (config-check.sh) reads this marker and alerts the user.

# Auto-detect config repo: try symlink source, then known paths
_detect_config_repo() {
    local hook_real
    hook_real="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")"
    if [[ -n "$hook_real" && -f "$(dirname "$hook_real")/../../sync.sh" ]]; then
        echo "$(cd "$(dirname "$hook_real")/../.." && pwd)"
        return
    fi
    for d in "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [[ -f "$d/sync.sh" ]] && echo "$d" && return
    done
    echo "$HOME/cfg-agent-fleet"  # final fallback
}
CONFIG_REPO="$(_detect_config_repo)"
FAIL_MARKER="$CONFIG_REPO/.sync-failed"
LOCK_FILE="$CONFIG_REPO/.sync-lock"
ROTATE_SCRIPT="$CONFIG_REPO/setup/scripts/rotate-session.sh"

# Capture the original working directory (the project the user was in)
ORIGINAL_DIR="$(pwd)"

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

# --- Phase 1: Auto-rotate current project's session ---
# If the project has a populated session-context.md, archive it before it goes stale.
# rotate-session.sh validates content and fails safely if template is blank.
if [[ -f "$ORIGINAL_DIR/session-context.md" && -s "$ORIGINAL_DIR/session-context.md" ]]; then
    bash "$ROTATE_SCRIPT" "$ORIGINAL_DIR" 2>/dev/null || true
fi

# --- Phase 2: Commit session files in current project (if separate from config repo) ---
# Only commits session-related files. Does NOT push (avoids dual-remote/auth issues).
if [[ "$ORIGINAL_DIR" != "$CONFIG_REPO" && -d "$ORIGINAL_DIR/.git" ]]; then
    (
        cd "$ORIGINAL_DIR" || exit 0
        git add session-context.md session-history.md 2>/dev/null || true
        git add docs/session-log.md 2>/dev/null || true
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "Auto-sync: session rotation $(date -u +'%Y-%m-%d %H:%M:%S UTC')" 2>/dev/null || true
        fi
    )
fi

# --- Phase 3: Config repo sync ---
cd "$CONFIG_REPO" 2>/dev/null || sync_fail "cd" "Config repo not found at $CONFIG_REPO"

# Acquire exclusive lock to prevent parallel session-end races.
# flock -n = non-blocking: if another session holds the lock, skip silently.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    # Another session-end hook is already running — skip to avoid conflicts
    exit 0
fi

# Auto-rotate config repo's own session (if different from original project)
if [[ "$ORIGINAL_DIR" != "$CONFIG_REPO" && -f "$CONFIG_REPO/session-context.md" && -s "$CONFIG_REPO/session-context.md" ]]; then
    bash "$ROTATE_SCRIPT" "$CONFIG_REPO" 2>/dev/null || true
fi

# Collect project-specific rules
COLLECT_OUTPUT=$(bash "$CONFIG_REPO/sync.sh" collect 2>&1) || sync_fail "collect" "sync.sh collect failed: $(echo "$COLLECT_OUTPUT" | tail -1)"

# Stage only expected directories and files — avoid staging unintended changes
git add session-context.md session-history.md 2>/dev/null || true
git add docs/ projects/ cross-project/ 2>/dev/null || true
git add global/ backlog.md registry.md template-sync-manifest.md 2>/dev/null || true
git diff --cached --quiet 2>/dev/null && sync_success  # Nothing to sync

# Secret scan: check staged diff for obvious secret patterns before committing
STAGED_DIFF=$(git diff --cached 2>/dev/null)
SECRET_PATTERNS='sk-ant-[A-Za-z0-9-]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|AIzaSy[A-Za-z0-9_-]{33}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|xoxb-[A-Za-z0-9-]+|xoxp-[A-Za-z0-9-]+|password\s*[:=]|secret\s*[:=]|private_key\s*[:=]|-----BEGIN RSA|-----BEGIN PRIVATE KEY|(key|token|secret)\s*[:=]\s*[A-Za-z0-9+/]{40,}={0,2}'
SECRET_HITS=$(printf '%s' "$STAGED_DIFF" | grep -E "$SECRET_PATTERNS" 2>/dev/null | grep '^+' | grep -v '^+++' || true)
if [ -n "$SECRET_HITS" ]; then
    # Identify which staged files contain the suspicious content (newline-separated)
    SUSPICIOUS_FILES=$(git diff --cached --name-only 2>/dev/null | while read -r f; do
        if git diff --cached -- "$f" 2>/dev/null | grep -qE "$SECRET_PATTERNS"; then
            echo "$f"
        fi
    done)
    if [ -n "$SUSPICIOUS_FILES" ]; then
        # Load into array to handle filenames with spaces safely
        mapfile -t SUSPICIOUS_ARRAY <<< "$SUSPICIOUS_FILES"
        git restore --staged "${SUSPICIOUS_ARRAY[@]}" 2>/dev/null || true
        printf 'AUTO-SYNC WARNING: Possible secrets detected in staged files: %s\n' \
            "${SUSPICIOUS_FILES//$'\n'/ }" >> "$CONFIG_REPO/.sync-warnings.log"
        printf 'time=%s\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" >> "$CONFIG_REPO/.sync-warnings.log"
        # If nothing left staged, exit cleanly (no commit needed)
        git diff --cached --quiet 2>/dev/null && sync_success
    fi
fi

# Commit
git commit -m "Auto-sync: $(date -u +'%Y-%m-%d %H:%M:%S UTC')" 2>/dev/null \
    || sync_fail "commit" "git commit failed"

# Push (auto-detect default branch: main or master)
# Respect dual-remote projects: push to private remote, never public
PUSH_REMOTE="origin"
if [ -f "$CONFIG_REPO/.push-filter.conf" ]; then
    PR=$(grep '^private_remote=' "$CONFIG_REPO/.push-filter.conf" 2>/dev/null | head -1 | cut -d= -f2 | xargs)
    [ -n "$PR" ] && PUSH_REMOTE="$PR"
fi
DEFAULT_BRANCH=$(git symbolic-ref "refs/remotes/$PUSH_REMOTE/HEAD" 2>/dev/null | sed "s|refs/remotes/$PUSH_REMOTE/||")
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"
git push "$PUSH_REMOTE" "$DEFAULT_BRANCH" 2>/dev/null \
    || sync_fail "push" "git push failed (network? auth?)"

sync_success
