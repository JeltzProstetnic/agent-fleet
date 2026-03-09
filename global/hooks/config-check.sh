#!/usr/bin/env bash
# SessionStart hook: check for config sync failures, symlink health, and inbox tasks.
# Outputs JSON with systemMessage so Claude sees the warning in context.

# Auto-detect config repo: try symlink source, then known paths
_detect_config_repo() {
    local hook_real
    hook_real="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")"
    if [[ -n "$hook_real" && -f "$(dirname "$hook_real")/../../sync.sh" ]]; then
        echo "$(cd "$(dirname "$hook_real")/../.." && pwd)"
        return
    fi
    for d in "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [[ -f "$d/sync.sh" && ! -f "$d/.template-repo" ]] && echo "$d" && return
    done
    echo "$HOME/cfg-agent-fleet"  # final fallback
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
    WARNINGS="CONFIG SYNC FAILED ($CONFIG_REPO) at $time — stage: $stage, detail: $detail. Run 'bash $CONFIG_REPO/sync.sh status' to diagnose. Uncommitted config changes may exist in $CONFIG_REPO/."
fi

# Check 2: Are symlinks intact and pointing to the right repo?
if [ ! -L "$HOME/.claude/CLAUDE.md" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }CLAUDE.md is not symlinked to config repo. Run 'bash $CONFIG_REPO/sync.sh setup' to restore."
elif [ -L "$HOME/.claude/CLAUDE.md" ]; then
    SYMLINK_TARGET="$(readlink -f "$HOME/.claude/CLAUDE.md" 2>/dev/null)"
    EXPECTED_TARGET="$(readlink -f "$CONFIG_REPO/global/CLAUDE.md" 2>/dev/null)"
    if [ -n "$SYMLINK_TARGET" ] && [ -n "$EXPECTED_TARGET" ] && [ "$SYMLINK_TARGET" != "$EXPECTED_TARGET" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }CLAUDE.md symlink points to wrong directory ($SYMLINK_TARGET instead of $EXPECTED_TARGET). Run 'bash $CONFIG_REPO/sync.sh setup' to fix."
    fi
fi

# Check 3: Does config repo exist?
if [ ! -d "$CONFIG_REPO/.git" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }Config repo not found at $CONFIG_REPO. Clone it and run: bash $CONFIG_REPO/sync.sh setup. If your repo is at ~/agent-fleet/, check if .template-repo exists and delete it (or run setup/install.sh which removes it automatically), then restart."
fi

# Check 4: Pull latest config (so inbox is current), and report changed files
if [ -d "$CONFIG_REPO/.git" ]; then
    # Respect dual-remote projects: pull from private remote, never public
    SYNC_REMOTE="origin"
    if [ -f "$CONFIG_REPO/.push-filter.conf" ]; then
        PR=$(grep '^private_remote=' "$CONFIG_REPO/.push-filter.conf" 2>/dev/null | head -1 | cut -d= -f2 | xargs)
        [ -n "$PR" ] && SYNC_REMOTE="$PR"
    fi
    OLD_HEAD=$(git -C "$CONFIG_REPO" rev-parse HEAD 2>/dev/null || true)
    if ! git -C "$CONFIG_REPO" pull --ff-only "$SYNC_REMOTE" "$DEFAULT_BRANCH" 2>/dev/null; then
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
    TASKS=$(grep "\- \[ \].*\*\*$PROJECT_NAME\*\*" "$INBOX" 2>/dev/null || true)
    if [ -n "$TASKS" ]; then
        INBOX_MSG="INBOX TASKS for $PROJECT_NAME: $TASKS"
    fi
    TOTAL=$(grep -c '\- \[ \]' "$INBOX" 2>/dev/null || echo "0")
    if [ "$TOTAL" -gt 0 ]; then
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }Cross-project inbox has $TOTAL pending task(s). Read $CONFIG_REPO/cross-project/inbox.md"
    fi
fi

# Check 7: Enforce Serena config (Serena regenerates defaults on update, wiping our settings)
SERENA_CONFIG="$HOME/.serena/serena_config.yml"
if [ -f "$SERENA_CONFIG" ]; then
    if grep -q 'web_dashboard_open_on_launch: true' "$SERENA_CONFIG"; then
        sed -i 's/web_dashboard_open_on_launch: true/web_dashboard_open_on_launch: false/' "$SERENA_CONFIG"
    fi
    if grep -q 'gui_log_window: true' "$SERENA_CONFIG"; then
        sed -i 's/gui_log_window: true/gui_log_window: false/' "$SERENA_CONFIG"
    fi
fi

# Check 8: Validate settings.json has all critical blocks
SETTINGS_FILE="$HOME/.cc-mirror/mclaude/config/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
    MISSING_BLOCKS=""
    for block in permissions hooks enabledPlugins; do
        if ! grep -q "\"$block\"" "$SETTINGS_FILE" 2>/dev/null; then
            MISSING_BLOCKS="${MISSING_BLOCKS:+$MISSING_BLOCKS, }$block"
        fi
    done
    if [ -n "$MISSING_BLOCKS" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }settings.json is missing critical blocks: $MISSING_BLOCKS. This causes permission prompt storms and broken hooks. Fix: run 'bash $CONFIG_REPO/setup/configure-claude.sh' to redeploy from template."
    fi
fi

# Check 9: Detect unmerged branches (mobile sessions create branches, not commits to main)
if [ -d "$CONFIG_REPO/.git" ]; then
    UNMERGED=$(git -C "$CONFIG_REPO" branch -r --no-merged "$DEFAULT_BRANCH" 2>/dev/null | grep -v HEAD | sed 's/^ *//' | tr '\n' ', ' | sed 's/, $//')
    if [ -n "$UNMERGED" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }Unmerged branches detected: $UNMERGED — mobile sessions work in branches. Review and cherry-pick useful commits, then delete the branch."
    fi
fi

# Check 10: Auto-remove stale permissions blocks from project settings.local.json
# Project-level permissions blocks REPLACE global permissions, causing prompt storms.
# They accumulate from "Always allow" clicks. Delegated to shared script.
CLEAN_PERMS_SCRIPT="$CONFIG_REPO/setup/scripts/clean-permissions.sh"
if [ -f "$CLEAN_PERMS_SCRIPT" ]; then
    bash "$CLEAN_PERMS_SCRIPT" 2>/dev/null || true
fi

# Check 11: Validate CLAUDE.local.md @import target exists
CLAUDE_LOCAL="$HOME/CLAUDE.local.md"
if [ -f "$CLAUDE_LOCAL" ]; then
    IMPORT_TARGET=$(grep '^@' "$CLAUDE_LOCAL" | head -1 | sed 's/^@//' | sed "s|~|$HOME|g")
    if [ -n "$IMPORT_TARGET" ] && [ ! -f "$IMPORT_TARGET" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }CLAUDE.local.md @import target does not exist: $IMPORT_TARGET — machine file is not being loaded. Check the filename."
    fi
fi

# Check 12: Detect uncollected mobile outbox tasks
MOBILE_REPO="$HOME/agent-fleet-mobile"
if [ -f "$MOBILE_REPO/inbox/outbox.md" ]; then
    MOBILE_TASKS=$(grep -c '^\- \[ \]' "$MOBILE_REPO/inbox/outbox.md" 2>/dev/null || echo "0")
    if [ "$MOBILE_TASKS" -gt 0 ] 2>/dev/null; then
        WARNINGS="${WARNINGS:+$WARNINGS | }Mobile outbox has $MOBILE_TASKS uncollected task(s). Run 'bash $CONFIG_REPO/sync.sh mobile-collect' to merge them into the inbox."
    fi
fi

# Check 13.5: Daily upstream dependency check (once per day, gated by marker file)
DEP_MARKER="$HOME/.claude/.dep-check-date"
DEP_TODAY=$(date +%Y-%m-%d)
DEP_LAST=$(cat "$DEP_MARKER" 2>/dev/null || echo "never")
if [ "$DEP_LAST" != "$DEP_TODAY" ]; then
    DEP_RESULTS=""
    # Claude Code version check
    if command -v npm >/dev/null 2>&1; then
        CC_LATEST=$(npm view @anthropic-ai/claude-code version 2>/dev/null || echo "?")
        CC_INSTALLED=""
        for pj in "$HOME"/.cc-mirror/*/npm/node_modules/@anthropic-ai/claude-code/package.json; do
            [ -f "$pj" ] && CC_INSTALLED=$(python3 -c "import json; print(json.load(open('$pj'))['version'])" 2>/dev/null) && break
        done
        if [ -n "$CC_INSTALLED" ] && [ -n "$CC_LATEST" ] && [ "$CC_LATEST" != "?" ] && [ "$CC_INSTALLED" != "$CC_LATEST" ]; then
            DEP_RESULTS="Claude Code update available: $CC_INSTALLED → $CC_LATEST (read changelog before updating)"
        fi
    fi
    mkdir -p "$(dirname "$DEP_MARKER")"
    echo "$DEP_TODAY" > "$DEP_MARKER"
    if [ -n "$DEP_RESULTS" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }Upstream dependency check: $DEP_RESULTS"
    fi
fi

# Check 13: Surface propagation drift warnings from previous session's sync.sh check
DRIFT_LOG="$CONFIG_REPO/.sync-warnings.log"
if [ -f "$DRIFT_LOG" ] && [ -s "$DRIFT_LOG" ]; then
    DRIFT_CONTENT=$(cat "$DRIFT_LOG" | tr '\n' '; ' | sed 's/; $//')
    WARNINGS="${WARNINGS:+$WARNINGS | }Propagation drift detected at last shutdown: $DRIFT_CONTENT. Run 'bash $CONFIG_REPO/sync.sh check' for details, then fix with 'bash $CONFIG_REPO/sync.sh deploy'."
    rm -f "$DRIFT_LOG"
fi

# Check 14: Auto-heal Bash(bash:*) in settings.json permissions.allow
# Without this permission, every `bash` command triggers a prompt — breaks startup/shutdown.
if [ -f "$SETTINGS_FILE" ]; then
    if grep -q '"permissions"' "$SETTINGS_FILE" 2>/dev/null; then
        if ! grep -q 'Bash(bash:\*)' "$SETTINGS_FILE" 2>/dev/null; then
            _bp_tmp="$(mktemp)"
            printf '%s\n' 'import json,sys' 'f=sys.argv[1]' 'd=json.load(open(f))' 'a=d.get("permissions",{}).get("allow")' 'if a is not None: a.append("Bash(bash:*)")' 'if a is not None: open(f,"w").write(json.dumps(d,indent=2)+"\n")' > "$_bp_tmp"
            python3 "$_bp_tmp" "$SETTINGS_FILE" 2>/dev/null || true
            rm -f "$_bp_tmp"
        fi
    fi
fi

# Check 15: Scan project tmp/ dirs for documents that should be in cross-machine storage
DOC_IN_TMP=""
for tmpdir in "$HOME"/*/tmp; do
    [ -d "$tmpdir" ] || continue
    FOUND=$(find "$tmpdir" -maxdepth 2 -type f \( -name "*.md" -o -name "*.pdf" -o -name "*.docx" -o -name "*.html" \) 2>/dev/null | head -5)
    if [ -n "$FOUND" ]; then
        COUNT=$(echo "$FOUND" | wc -l)
        DOC_IN_TMP="${DOC_IN_TMP:+$DOC_IN_TMP, }$tmpdir ($COUNT files)"
    fi
done
if [ -n "$DOC_IN_TMP" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }Documents found in project tmp/ dirs: $DOC_IN_TMP — these should be in DMS/NAS/Dropbox for cross-machine access. Tell the user about this issue immediately before doing any other work."
fi

# Check 17: Warn on stale pending files (>2 days old) with backlog cross-check
STALE_PENDING=""
STALE_UNTRACKED=""
if [ -d "$PROJECT_DIR/docs" ]; then
    BACKLOG_FILE="$PROJECT_DIR/backlog.md"
    for pf in "$PROJECT_DIR"/docs/pending-*.md; do
        [ -f "$pf" ] || continue
        FILE_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$pf" 2>/dev/null || echo "$(date +%s)") ) / 86400 ))
        if [ "$FILE_AGE_DAYS" -ge 2 ]; then
            PF_BASE="$(basename "$pf")"
            STALE_PENDING="${STALE_PENDING:+$STALE_PENDING, }${PF_BASE} (${FILE_AGE_DAYS}d)"
            if [ -f "$BACKLOG_FILE" ] && ! grep -q "$PF_BASE" "$BACKLOG_FILE" 2>/dev/null; then
                STALE_UNTRACKED="${STALE_UNTRACKED:+$STALE_UNTRACKED, }${PF_BASE} (no backlog item)"
            fi
        fi
    done
fi
if [ -n "$STALE_PENDING" ]; then
    STALE_MSG="Stale pending files (>2 days): $STALE_PENDING — address, promote to backlog, or delete."
    if [ -n "$STALE_UNTRACKED" ]; then
        STALE_MSG="$STALE_MSG Untracked: $STALE_UNTRACKED"
    fi
    WARNINGS="${WARNINGS:+$WARNINGS | }$STALE_MSG"
fi

# Check 18: Auto-disable global enabledPlugins (token budget protection)
# Plugin agent descriptions consume ~10k tokens per bundle. Global plugins affect ALL projects.
if [ -f "$SETTINGS_FILE" ]; then
    if grep -q '"enabledPlugins"' "$SETTINGS_FILE" 2>/dev/null; then
        _ep_tmp="$(mktemp)"
        printf '%s\n' 'import json,sys' 'f=sys.argv[1]' 'd=json.load(open(f))' 'ep=d.get("enabledPlugins",{})' 'n=len(ep)' 'if n>0: d["enabledPlugins"]={}; open(f,"w").write(json.dumps(d,indent=2)+"\n")' 'print(n)' > "$_ep_tmp"
        _ep_count=$(python3 "$_ep_tmp" "$SETTINGS_FILE" 2>/dev/null || echo "0")
        rm -f "$_ep_tmp"
        if [ "$_ep_count" -gt 0 ]; then
            WARNINGS="${WARNINGS:+$WARNINGS | }Global enabledPlugins had $_ep_count plugin(s) — auto-disabled. Plugins consume ~10k tokens/bundle. Enable per-project only via .claude/settings.local.json."
        fi
    fi
fi

# Check 19: Inject hostname + time for machine identity and day/night mode
# Avoids Read /etc/hostname permission prompt and Bash date calls (saves 2 tool calls per session)
HOSTNAME_VAL=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")
CURRENT_TIME=$(date +%H:%M)
DAY_OF_WEEK=$(date +%u)
INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }HOSTNAME: $HOSTNAME_VAL | TIME: $CURRENT_TIME DOW: $DAY_OF_WEEK"

# Check 20: Persona injection — read active persona, inject into systemMessage
ACTIVE_PERSONA_FILE="$HOME/.claude/.active-persona"
PERSONA_NAME="Assistant"
if [ -f "$ACTIVE_PERSONA_FILE" ]; then
    _raw_persona=$(head -1 "$ACTIVE_PERSONA_FILE" 2>/dev/null | xargs)
    [ -n "$_raw_persona" ] && PERSONA_NAME="$_raw_persona"
fi
INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }PERSONA: $PERSONA_NAME"

# Check 21: Session-context blank detection — detect active session goal
if [[ -f "$PROJECT_DIR/session-context.md" ]]; then
    _sc_goal=$(sed -n 's/.*\*\*Session Goal\*\*: \(.\+\)/\1/p' "$PROJECT_DIR/session-context.md" 2>/dev/null | head -1)
    if [[ -n "$_sc_goal" ]]; then
        _sc_goal="${_sc_goal:0:150}"
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }SESSION_CONTEXT: active — $_sc_goal"
    else
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }SESSION_CONTEXT: blank"
    fi
else
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }SESSION_CONTEXT: blank"
fi

# Check 22: Handoff detection — read next-session-task.md, inject HANDOFF
HANDOFF_FILE="$PROJECT_DIR/next-session-task.md"
if [[ -f "$HANDOFF_FILE" ]]; then
    _ho_task=$(grep '^task:' "$HANDOFF_FILE" 2>/dev/null | head -1 | sed 's/^task: *//')
    if [[ "$_ho_task" == "true" ]]; then
        _ho_desc=$(grep '^description:' "$HANDOFF_FILE" 2>/dev/null | head -1 | sed 's/^description: *//')
        _ho_file=$(grep '^file:' "$HANDOFF_FILE" 2>/dev/null | head -1 | sed 's/^file: *//')
        _ho_desc="${_ho_desc:0:200}"
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }HANDOFF: $_ho_desc | file: $_ho_file"
    else
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }HANDOFF: none"
    fi
else
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }HANDOFF: none"
fi

# Check 23: Pending files list — list all pending-*.md files in project docs/
_pending_list=""
if [ -d "$PROJECT_DIR/docs" ]; then
    for _pf in "$PROJECT_DIR"/docs/pending-*.md; do
        [ -f "$_pf" ] || continue
        _pf_base="$(basename "$_pf")"
        _pending_list="${_pending_list:+$_pending_list, }$_pf_base"
    done
fi
if [ -n "$_pending_list" ]; then
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }PENDING_FILES: $_pending_list"
else
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }PENDING_FILES: none"
fi

# Check 24: Knowledge file list — list .claude/knowledge/*.md + .claude/*.md
_knowledge_list=""
if [ -d "$PROJECT_DIR/.claude" ]; then
    for _kf in "$PROJECT_DIR"/.claude/knowledge/*.md; do
        [ -f "$_kf" ] || continue
        _knowledge_list="${_knowledge_list:+$_knowledge_list, }$(basename "$_kf")"
    done
    for _kf in "$PROJECT_DIR"/.claude/*.md; do
        [ -f "$_kf" ] || continue
        _kf_base="$(basename "$_kf")"
        [[ "$_kf_base" == settings* ]] && continue
        _knowledge_list="${_knowledge_list:+$_knowledge_list, }$_kf_base"
    done
fi
if [ -n "$_knowledge_list" ]; then
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }PROJECT_KNOWLEDGE: $_knowledge_list"
else
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }PROJECT_KNOWLEDGE: none"
fi

# Check 25: AFD/afleet dashboard marker — deferred startup with auto-dashboard
DASH_MARKER="$HOME/.claude/.afleet-show-dash"
if [ -f "$DASH_MARKER" ]; then
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }AFLEET_DASHBOARD: Show project dashboard (lsd) immediately as first response — read ONLY $CONFIG_REPO/cross-project/dashboard-cache.md, render per lsd-spec.md. Skip startup protocol entirely. If user enters a number or project name, treat as project switch. Only run full startup if user gives a non-dashboard, non-switch command."
    rm -f "$DASH_MARKER"
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
