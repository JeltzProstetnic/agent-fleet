# Check group 3: Inbox and service config — inbox tasks, Serena, settings, branches
# Checks: 5.5, 6, 7, 8, 9
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX_MSG, SETTINGS_FILE, DEFAULT_BRANCH

# Check 5.5: Run mobile-collect BEFORE reading inbox (Bug 1 fix — ensures mobile
# tasks are merged into inbox before Check 6 surfaces them to Claude)
MOBILE_REPO="${USER_HOME:-$HOME}/agent-fleet-mobile"
if [ -d "$MOBILE_REPO" ] && [ -f "$MOBILE_REPO/inbox/outbox.md" ]; then
    MOBILE_TASKS=$(grep -c '^\- \[ \]' "$MOBILE_REPO/inbox/outbox.md" 2>/dev/null || echo "0")
    if [ "$MOBILE_TASKS" -gt 0 ] 2>/dev/null; then
        bash "$CONFIG_REPO/setup/scripts/mobile-deploy.sh" --collect \
            --config-repo "$CONFIG_REPO" \
            --target "$MOBILE_REPO" >/dev/null 2>&1 || true
    fi
fi

# Check 6: Cross-project inbox — surface pending tasks for current project
INBOX="$CONFIG_REPO/cross-project/inbox.md"
if [ -f "$INBOX" ]; then
    PROJECT_NAME=$(basename "$(pwd)")
    # The tag match is case-INSENSITIVE and tolerates padding inside the `**...**`.
    # It used to be exact — 30 items whose tag differed only in casing were invisible to
    # their project for a month, neither delivered nor reported undelivered.
    TASKS=$(grep -i "\- \[ \].*\*\*[[:space:]]*$PROJECT_NAME[[:space:]]*\*\*" "$INBOX" 2>/dev/null || true)
    if [ -n "$TASKS" ]; then
        INBOX_MSG="INBOX TASKS for $PROJECT_NAME: $TASKS"
    fi
    # Report a COUNT only — never instruct the model to read the whole inbox. This file
    # grows without bound, and a full read costs tens of thousands of tokens every session.
    # Items for this project are already injected above; other projects' items are not needed.
    TOTAL=$(grep -c '\- \[ \]' "$INBOX" 2>/dev/null || echo "0")
    PROJECT_COUNT=$(echo "$TASKS" | grep -c '\- \[ \]' 2>/dev/null || echo "0")
    [ -z "$TASKS" ] && PROJECT_COUNT=0
    OTHER_COUNT=$((TOTAL - PROJECT_COUNT))
    if [ "$OTHER_COUNT" -gt 0 ]; then
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }Cross-project inbox: $OTHER_COUNT task(s) for other projects (total: $TOTAL)"
    fi

    # Bound the inbox. Reporting a count only means unbounded growth emits the same signal
    # at 3 items as at 300 — so add thresholds. A raw count is not a signal.
    # NOTE: stdout here is a JSON contract — warnings go to $WARNINGS, never echo.
    _inbox_tok=$(( $(wc -c < "$INBOX" 2>/dev/null || echo 0) / 4 ))
    if [ "$_inbox_tok" -gt "${INBOX_TOKEN_CEILING:-20000}" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }INBOX_OVERSIZE: cross-project/inbox.md is ~${_inbox_tok} tokens (ceiling ${INBOX_TOKEN_CEILING:-20000}) across $TOTAL open item(s) — promote them into project backlogs and delete them."
    fi
    _inbox_old=$(awk -v cutoff="$(date -d '30 days ago' +%Y-%m-%d 2>/dev/null || echo 0000-00-00)" \
        'match($0, /20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
            d = substr($0, RSTART, RLENGTH); if (d < cutoff) n++
         } END { print n+0 }' "$INBOX" 2>/dev/null || echo 0)
    if [ "$_inbox_old" -gt 0 ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }INBOX_STALE: $_inbox_old inbox line(s) carry a date older than 30 days — an inbox item that survives a month was never a handoff, it is untracked work. Promote to a backlog and delete."
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
