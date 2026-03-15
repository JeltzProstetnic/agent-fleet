# Check group 3: Inbox and service config — inbox tasks, Serena, settings, branches
# Checks: 6, 7, 8, 9
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX_MSG, SETTINGS_FILE, DEFAULT_BRANCH

# Check 6: Cross-project inbox — surface pending tasks for current project
INBOX="$CONFIG_REPO/cross-project/inbox.md"
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
