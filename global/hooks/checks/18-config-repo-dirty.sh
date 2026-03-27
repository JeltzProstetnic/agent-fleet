#!/usr/bin/env bash
# Check group 18: Config repo dirty state + ghost session detection
# Detects uncommitted changes in cfg-agent-fleet at session start.
# Also detects ghost sessions: blank session-context.md + dirty repo = previous
# session made changes but never committed or shut down properly.
# Shared vars used: CONFIG_REPO, WARNINGS, PROJECT_DIR

# Only check if config repo is a git repo
[ -d "$CONFIG_REPO/.git" ] || return 0 2>/dev/null || true

# Check for uncommitted changes (modified tracked files, staged or unstaged)
# Exclude untracked files (??) — those are normal (tmp/, gitignored, etc.)
_dirty_files=$(git -C "$CONFIG_REPO" status --porcelain 2>/dev/null | grep -v '^??' | sed 's/^...//' || true)

if [ -n "$_dirty_files" ]; then
    _dirty_count=$(echo "$_dirty_files" | wc -l | tr -d ' ')
    _dirty_list=$(echo "$_dirty_files" | tr '\n' ', ' | sed 's/,$//')
    WARNINGS="${WARNINGS:+$WARNINGS | }CONFIG_REPO_DIRTY: $(basename "$CONFIG_REPO") has $_dirty_count uncommitted file(s): $_dirty_list. Previous session left changes without committing. Run 'git -C $CONFIG_REPO diff' to review."

    # Ghost session detection: if we're IN the config repo project AND
    # session-context.md is blank (freshly rotated) but repo has uncommitted changes,
    # a previous session made edits and never shut down properly.
    if [[ "$PROJECT_DIR" == "$CONFIG_REPO" || "$PROJECT_DIR" == "$CONFIG_REPO/"* ]]; then
        _session_goal=""
        if [ -f "$CONFIG_REPO/session-context.md" ]; then
            _session_goal=$(sed -n 's/.*\*\*Session Goal\*\*: \(.\+\)/\1/p' "$CONFIG_REPO/session-context.md" 2>/dev/null | head -1)
        fi
        if [ -z "$_session_goal" ]; then
            WARNINGS="${WARNINGS:+$WARNINGS | }GHOST_SESSION: Previous $(basename "$CONFIG_REPO") session left $_dirty_count uncommitted file(s) without logging to session-log.md. Review changes, commit or revert, then proceed."
        fi
    fi
fi

# Collect-uncommitted marker — written by sync.sh collect when it
# skips hooks due to uncommitted edits in the repo.
_collect_marker="$CONFIG_REPO/.collect-uncommitted-hooks"
if [ -f "$_collect_marker" ]; then
    _marker_files=$(grep '^files=' "$_collect_marker" 2>/dev/null | cut -d= -f2-)
    _marker_ts=$(grep '^timestamp=' "$_collect_marker" 2>/dev/null | cut -d= -f2-)
    WARNINGS="${WARNINGS:+$WARNINGS | }COLLECT_BLOCKED: sync.sh collect skipped hooks due to uncommitted edits (${_marker_ts:-unknown time}): ${_marker_files:-unknown files}. Commit or revert the edits, then delete $_collect_marker."
fi
