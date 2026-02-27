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

# Auto-detect config repo: try symlink source, then known paths
_detect_config_repo() {
    local hook_real
    hook_real="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")"
    if [[ -n "$hook_real" && -f "$(dirname "$hook_real")/../../sync.sh" ]]; then
        cd "$(dirname "$hook_real")/../.." && pwd
        return
    fi
    for d in "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [[ -f "$d/sync.sh" ]] && echo "$d" && return
    done
    echo "$HOME/cfg-agent-fleet"  # final fallback
}
CONFIG_REPO="$(_detect_config_repo)"
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

# Secret scan: check staged diff for obvious secret patterns before committing
STAGED_DIFF=$(git diff --cached 2>/dev/null)
SECRET_PATTERNS='sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|xoxb-[A-Za-z0-9-]+|xoxp-[A-Za-z0-9-]+|password\s*[:=]|secret\s*[:=]|private_key\s*[:=]|BEGIN RSA|BEGIN PRIVATE KEY|[A-Za-z0-9+/]{40,}={0,2}'
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
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"
git push origin "$DEFAULT_BRANCH" 2>/dev/null \
    || sync_fail "push" "git push failed (network? auth?)"

sync_success
