# Check group 4: Auto-fix — permissions, CLAUDE.local, FMS, drift, deps, AFD, bash perm
# Checks: 10, 11, 12, 14, 13, 13.5, 13b
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX_MSG, SETTINGS_FILE

# Check 10: Auto-remove stale permissions blocks from project settings.local.json
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

# Check 12: FMS intake — report pending files across all drop locations
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

# Check 14: Auto-heal Bash(bash:*) in settings.json permissions.allow
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

# Check 13: Surface propagation drift warnings from previous session's sync.sh check
DRIFT_LOG="$CONFIG_REPO/.sync-warnings.log"
if [ -f "$DRIFT_LOG" ] && [ -s "$DRIFT_LOG" ]; then
    DRIFT_CONTENT=$(cat "$DRIFT_LOG" | tr '\n' '; ' | sed 's/; $//')
    WARNINGS="${WARNINGS:+$WARNINGS | }Propagation drift detected at last shutdown: $DRIFT_CONTENT. Run 'bash $CONFIG_REPO/sync.sh check' for details, then fix with 'bash $CONFIG_REPO/sync.sh deploy'."
    rm -f "$DRIFT_LOG"
fi

# Check 13.5: Daily upstream dependency check (once per day, gated by marker file)
DEP_MARKER="$HOME/.claude/.dep-check-date"
DEP_TODAY=$(date +%Y-%m-%d)
DEP_LAST=$(cat "$DEP_MARKER" 2>/dev/null || echo "never")
if [ "$DEP_LAST" != "$DEP_TODAY" ]; then
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
    mkdir -p "$(dirname "$DEP_MARKER")"
    echo "$DEP_TODAY" > "$DEP_MARKER"
    if [ -n "$DEP_RESULTS" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }Upstream dependency check: $DEP_RESULTS"
    fi
fi

# Check 13b: AFD client deployed — auto-source env if available
if [ -f "$HOME/.afd-env" ] && [ -z "${AFD_TOKEN:-}" ]; then
    . "$HOME/.afd-env" 2>/dev/null || true
fi
if [ -f "$HOME/.local/bin/afd" ] && [ -z "${AFD_TOKEN:-}" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }AFD client installed but AFD_TOKEN not set. Run vault-manage.sh deploy or set AFD_TOKEN in environment."
fi
