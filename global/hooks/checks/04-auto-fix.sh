#!/usr/bin/env bash
# Check group 4: Auto-fix — permissions, CLAUDE.local, FMS, drift, deps, AFD, bash perm
# Checks: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX_MSG, SETTINGS_FILE

# Check 4.1: Auto-remove stale permissions blocks from project settings.local.json
CLEAN_PERMS_SCRIPT="$CONFIG_REPO/setup/scripts/clean-permissions.sh"
if [ -f "$CLEAN_PERMS_SCRIPT" ]; then
    bash "$CLEAN_PERMS_SCRIPT" 2>/dev/null || true
fi

# Check 4.2: Validate CLAUDE.local.md @import target exists
CLAUDE_LOCAL="$HOME/CLAUDE.local.md"
if [ -f "$CLAUDE_LOCAL" ]; then
    IMPORT_TARGET=$(grep '^@' "$CLAUDE_LOCAL" | head -1 | sed 's/^@//' | sed "s|~|$HOME|g")
    if [ -n "$IMPORT_TARGET" ] && [ ! -f "$IMPORT_TARGET" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }CLAUDE.local.md @import target does not exist: $IMPORT_TARGET — machine file is not being loaded. Check the filename."
    fi
fi

# Check 4.3: FMS intake — report pending files across all drop locations
FMS_MSG=""
FMS_SCRIPT="$CONFIG_REPO/dms/scripts/fms-intake.sh"
if [ -x "$FMS_SCRIPT" ] || [ -f "$FMS_SCRIPT" ]; then
    FMS_COUNT=$(bash "$FMS_SCRIPT" count 2>/dev/null || echo "0")
    if [ "$FMS_COUNT" -gt 0 ]; then
        FMS_MSG="FMS: $FMS_COUNT file(s) pending classification. Run 'bash $FMS_SCRIPT scan' to review."
    fi
fi
if [ -n "$FMS_MSG" ]; then
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }$FMS_MSG"
fi

# Check 4.4: Auto-heal Bash(bash:*) in settings.json permissions.allow
if [ -f "$SETTINGS_FILE" ]; then
    if grep -q '"permissions"' "$SETTINGS_FILE" 2>/dev/null; then
        if ! grep -q 'Bash(bash:\*)' "$SETTINGS_FILE" 2>/dev/null; then
            _bp_tmp="$(mktemp)"
            printf '%s\n' 'import json,sys,os' 'f=sys.argv[1]' 'd=json.load(open(f))' 'a=d.get("permissions",{}).get("allow")' 'if a is not None: a.append("Bash(bash:*)")' 'if a is not None:' '  t=f+".tmp"' '  open(t,"w").write(json.dumps(d,indent=2)+"\n")' '  os.rename(t,f)' > "$_bp_tmp"
            python3 "$_bp_tmp" "$SETTINGS_FILE" 2>/dev/null || true
            rm -f "$_bp_tmp"
        fi
    fi
fi

# Check 4.5: Surface propagation drift warnings from previous session's sync.sh check
DRIFT_LOG="$CONFIG_REPO/.sync-warnings.log"
if [ -f "$DRIFT_LOG" ] && [ -s "$DRIFT_LOG" ]; then
    DRIFT_CONTENT=$(cat "$DRIFT_LOG" | tr '\n' '; ' | sed 's/; $//')
    WARNINGS="${WARNINGS:+$WARNINGS | }Propagation drift detected at last shutdown: $DRIFT_CONTENT. Run 'bash $CONFIG_REPO/sync.sh check' for details, then fix with 'bash $CONFIG_REPO/sync.sh deploy'."
    rm -f "$DRIFT_LOG"
fi

# Check 4.5b: Surface T2 deployment-critical edit warnings (CFG-326)
T2_MARKER="$CONFIG_REPO/.t2-edits-pending"
if [ -f "$T2_MARKER" ] && [ -s "$T2_MARKER" ]; then
    T2_CONTENT=$(cat "$T2_MARKER")
    WARNINGS="${WARNINGS:+$WARNINGS | }$T2_CONTENT — run E2E tests before release: bash setup/tests/run.sh && vm-exec.sh afleet-e2e"
    rm -f "$T2_MARKER"
fi

# Check 4.6: Daily upstream dependency check (once per day, gated by sched-lib)
_dep_sched_lib="${CONFIG_REPO:-}/setup/scripts/sched-lib.sh"
_dep_run=1
if [ -f "$_dep_sched_lib" ]; then
    source "$_dep_sched_lib"
    SCHED_MARKER_DIR="${SCHED_MARKER_DIR:-/tmp}"
    sched_is_due "cc-dep-check" "daily" || _dep_run=0
else
    # fallback inline marker
    _dep_gate="/tmp/.cc-dep-check-$(date +%Y-%m-%d)"
    [ ! -f "$_dep_gate" ] || _dep_run=0
    [ "$_dep_run" -eq 1 ] && touch "$_dep_gate"
fi
if [ "$_dep_run" -eq 1 ]; then
    DEP_RESULTS=""
    if command -v npm >/dev/null 2>&1; then
        CC_LATEST=$(timeout 5 npm view @anthropic-ai/claude-code version 2>/dev/null || echo "?")
        CC_INSTALLED=""
        for pj in "$HOME"/.cc-mirror/*/npm/node_modules/@anthropic-ai/claude-code/package.json; do
            [ -f "$pj" ] && CC_INSTALLED=$(python3 -c "import json; print(json.load(open('$pj'))['version'])" 2>/dev/null) && break
        done
        if [ -n "$CC_INSTALLED" ] && [ -n "$CC_LATEST" ] && [ "$CC_LATEST" != "?" ] && [ "$CC_INSTALLED" != "$CC_LATEST" ]; then
            DEP_RESULTS="Claude Code update available: $CC_INSTALLED → $CC_LATEST (read changelog before updating)"
        fi
    fi
    # Mark done (sched-lib or fallback)
    if type sched_mark_done &>/dev/null; then
        sched_mark_done "cc-dep-check" "daily"
    elif [ -z "${_dep_gate:-}" ]; then
        touch "/tmp/.cc-dep-check-$(date +%Y-%m-%d)"
    fi
    if [ -n "$DEP_RESULTS" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }Upstream dependency check: $DEP_RESULTS"
    fi
fi

# Check 4.7: MEMORY.md / memory/ violation detection (fleet rules prohibit auto-memory)
if [ -f "$PROJECT_DIR/MEMORY.md" ] || [ -d "$PROJECT_DIR/memory" ]; then
    _mem_targets=""
    [ -f "$PROJECT_DIR/MEMORY.md" ] && _mem_targets="MEMORY.md"
    [ -d "$PROJECT_DIR/memory" ] && _mem_targets="${_mem_targets:+$_mem_targets or }memory/"
    WARNINGS="${WARNINGS:+$WARNINGS | }[WARN] $PROJECT_DIR has $_mem_targets — fleet rules prohibit auto-memory. Delete and use proper fleet structure."
fi

# Check 4.8b: MCP config symlink health — auto-fix broken ~/.mcp.json
# workspace-mcp and other MCP servers silently fail to register when this symlink is broken.
# The user sees no error — Gmail/Calendar/Drive tools simply don't appear in the session.
_MCP_LINK="$HOME/.mcp.json"
_MCP_TARGET="$CC_MIRROR_DIR/config/.mcp.json"
if [ -L "$_MCP_LINK" ] && [ ! -e "$_MCP_LINK" ]; then
    # Broken symlink — auto-fix
    if [ -f "$_MCP_TARGET" ]; then
        rm -f "$_MCP_LINK"
        ln -s "$_MCP_TARGET" "$_MCP_LINK" 2>/dev/null
        if [ ! -e "$_MCP_LINK" ]; then
            WARNINGS="${WARNINGS:+$WARNINGS | }~/.mcp.json is a broken symlink and auto-fix failed. MCP servers (Gmail, Calendar, etc.) will not work. Fix: ln -s $_MCP_TARGET $_MCP_LINK"
        fi
        # Silent on success (auto-fix over warn)
    else
        WARNINGS="${WARNINGS:+$WARNINGS | }~/.mcp.json is a broken symlink and no canonical MCP config found at $_MCP_TARGET. MCP servers will not work."
    fi
elif [ ! -e "$_MCP_LINK" ] && [ -f "$_MCP_TARGET" ]; then
    # Missing entirely — create it
    ln -s "$_MCP_TARGET" "$_MCP_LINK" 2>/dev/null || true
fi

# Check 4.8: AFD client deployed — auto-source env if available
if [ -f "$HOME/.afd-env" ] && [ -z "${AFD_TOKEN:-}" ]; then
    . "$HOME/.afd-env" 2>/dev/null || true
fi
if [ -f "$HOME/.local/bin/afd" ] && [ -z "${AFD_TOKEN:-}" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }AFD client installed but AFD_TOKEN not set. Run vault-manage.sh deploy or set AFD_TOKEN in environment."
fi
