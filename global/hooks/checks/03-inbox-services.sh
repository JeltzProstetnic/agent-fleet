#!/usr/bin/env bash
# Check group 3: Inbox and service config — inbox delivery, Serena, settings, branches
# Checks: 3.1, 3.2, 3.2c (child surfacing), 3.3, 3.4, 3.5
# Typed delivery of this project's items is in 03b-inbox-typing.sh; corpus health (3.2b
# unknown tags, 3.2d size/age, 3.2e unreachable files) moved to 03c-inbox-health.sh on
# 2026-11-25 (CFG-1091, 150-line limit). Both run after this file by filename order.
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX_MSG, SETTINGS_FILE, DEFAULT_BRANCH
# Sets for 03b/03c: INBOX, PROJECT_NAME, PROJECT_ALIASES, TASKS, TOTAL

# Check 3.1: Run mobile-collect BEFORE reading inbox (Bug 1 fix — ensures mobile
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

# Check 3.2: Cross-project inbox — surface pending tasks for current project
# CFG-483: the tag match is case-INSENSITIVE and tolerates padding inside the
# `**...**`. It used to be exact, so 30 items whose tag differed only in casing were
# invisible to their project for a month — neither delivered nor reported undelivered.
INBOX="$CONFIG_REPO/cross-project/inbox.md"
# CFG-542: per-project files are canonical; the legacy file is still read so that
# un-migrated writers keep working. The library degrades to legacy-only when the
# inbox directory is absent, so an un-migrated machine behaves exactly as before.
_INBOX_LIB="$CONFIG_REPO/setup/scripts/inbox-lib.sh"
# shellcheck disable=SC1090
[ -f "$_INBOX_LIB" ] && . "$_INBOX_LIB" 2>/dev/null
if [ -f "$INBOX" ] || [ -d "$CONFIG_REPO/cross-project/inbox" ]; then
    PROJECT_NAME=$(basename "$(pwd)")
    PROJECT_ALIASES="$PROJECT_NAME"
    if command -v inbox_items_for_any >/dev/null 2>&1; then
        # CFG-1091 D2: a session answers to its directory name AND its registry name.
        # fleet-auditor lives in auditor/, so inbox/fleet-auditor.md was read by nobody
        # and its mail sat for four months with no signal. Same for any project whose
        # registry Path basename differs from its name.
        PROJECT_ALIASES=$(inbox_names_for_dir "$(pwd)" 2>/dev/null | tr '\n' ' ')
        PROJECT_ALIASES="${PROJECT_ALIASES% }"
        [ -n "$PROJECT_ALIASES" ] || PROJECT_ALIASES="$PROJECT_NAME"
        # shellcheck disable=SC2086
        TASKS=$(inbox_items_for_any $PROJECT_ALIASES 2>/dev/null || true)
    else
        TASKS=$(grep -i "\- \[ \].*\*\*[[:space:]]*$PROJECT_NAME[[:space:]]*\*\*" "$INBOX" 2>/dev/null || true)
    fi
    # Delivery of $TASKS moved to checks/03b-inbox-typing.sh (CFG-541): items are
    # emitted grouped by type with `fact` leading, because an untyped list of N
    # items of unknown cost is the thing that made this queue undrainable.
    # TASKS is still computed here — the counts below need it.
    # Only report total count — don't tell model to read full inbox (wastes 50k+ context).
    # Project-specific tasks are already injected above; other projects' tasks aren't needed.
    if command -v inbox_total_count >/dev/null 2>&1; then
        TOTAL=$(inbox_total_count 2>/dev/null || echo "0")
    else
        TOTAL=$(grep -c '\- \[ \]' "$INBOX" 2>/dev/null || echo "0")
    fi
    [ -n "$TOTAL" ] || TOTAL=0
    PROJECT_COUNT=$(echo "$TASKS" | grep -c '\- \[ \]' 2>/dev/null || echo "0")
    [ -z "$TASKS" ] && PROJECT_COUNT=0
    OTHER_COUNT=$((TOTAL - PROJECT_COUNT))
    if [ "$OTHER_COUNT" -gt 0 ]; then
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }Cross-project inbox: $OTHER_COUNT task(s) for other projects (total: $TOTAL)"
    fi

    # Check 3.2c (CFG-134): a child project's items sit in the inbox until that
    # child gets its own session, which for most children is rarely — while the
    # PARENT's session runs constantly and never saw them. The registry has had a
    # Parent column all along and this check never read it. CLAUDE.md already
    # tells the parent to report child items without deleting them; it just had
    # no way to see them short of reading the whole ~100k-token inbox by hand.
    #
    # CFG-1091 D4: since CFG-542 this grepped only the legacy file, where no item
    # has lived for three months — acme saw 0 of 13 child items, home 0 of 13.
    # inbox_child_report reads the per-project files and TRUNCATES bodies on
    # purpose: the parent needs enough to tell the user a child has mail, not the
    # full item (CFG-515).
    _CHILD_MSG=""
    if command -v inbox_child_report >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        _CHILD_MSG=$(inbox_child_report $PROJECT_ALIASES 2>/dev/null || true)
    elif [ -f "$CONFIG_REPO/registry.md" ]; then
        # No library (un-migrated machine): registry Parent column + legacy file, as before.
        _CHILDREN=$(sed -n '/^## Projects/,/^## [^P]/p' "$CONFIG_REPO/registry.md" 2>/dev/null \
            | awk -F'|' -v parent="$PROJECT_NAME" 'NF > 3 {
                name = $2; par = $4; gsub(/^[ \t]+|[ \t]+$/, "", name); gsub(/^[ \t]+|[ \t]+$/, "", par)
                if (name != "" && name != "Project" && name !~ /^-+$/ && tolower(par) == tolower(parent)) print name }' 2>/dev/null || true)
        while IFS= read -r _child; do
            [ -n "$_child" ] || continue
            _citems=$(grep -i -- "- \[ \].*\*\*[[:space:]]*$_child[[:space:]]*\*\*" "$INBOX" 2>/dev/null || true)
            [ -n "$_citems" ] || continue
            _ccount=$(printf '%s\n' "$_citems" | grep -c -- '- \[ \]' 2>/dev/null | head -1); [ -n "$_ccount" ] || _ccount=1
            _cbrief=$(printf '%s\n' "$_citems" | head -n 5 | cut -c1-160 | tr '\n' '~' | sed 's/~$//; s/~/ … /g')
            _CHILD_MSG="${_CHILD_MSG:+$_CHILD_MSG | }$_child ($_ccount item(s)): $_cbrief"
        done <<EOF
$_CHILDREN
EOF
    fi
    if [ -n "$_CHILD_MSG" ]; then
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }INBOX TASKS for CHILD project(s) — report these to the user but do NOT delete them; each child's own session promotes and clears its own items: $_CHILD_MSG"
    fi
fi

# Check 3.3: Enforce Serena config (Serena regenerates defaults on update, wiping our settings)
SERENA_CONFIG="$HOME/.serena/serena_config.yml"
if [ -f "$SERENA_CONFIG" ]; then
    if grep -q 'web_dashboard_open_on_launch: true' "$SERENA_CONFIG"; then
        sed -i 's/web_dashboard_open_on_launch: true/web_dashboard_open_on_launch: false/' "$SERENA_CONFIG"
    fi
    if grep -q 'gui_log_window: true' "$SERENA_CONFIG"; then
        sed -i 's/gui_log_window: true/gui_log_window: false/' "$SERENA_CONFIG"
    fi
fi

# Check 3.4: Validate settings.json has all critical blocks
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

# Check 3.5: Detect unmerged branches (mobile sessions create branches, not commits to main)
if [ -d "$CONFIG_REPO/.git" ]; then
    UNMERGED=$(git -C "$CONFIG_REPO" branch -r --no-merged "$DEFAULT_BRANCH" 2>/dev/null | grep -v HEAD | sed 's/^ *//' | tr '\n' ', ' | sed 's/, $//')
    if [ -n "$UNMERGED" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }Unmerged branches detected: $UNMERGED — mobile sessions work in branches. Review and cherry-pick useful commits, then delete the branch."
    fi
fi
