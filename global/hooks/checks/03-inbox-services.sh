#!/usr/bin/env bash
# Check group 3: Inbox and service config — inbox tasks, Serena, settings, branches
# Checks: 3.1, 3.2, 3.3, 3.4, 3.5
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX_MSG, SETTINGS_FILE, DEFAULT_BRANCH

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
    if command -v inbox_items_for >/dev/null 2>&1; then
        TASKS=$(inbox_items_for "$PROJECT_NAME" 2>/dev/null || true)
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
    # Bodies are TRUNCATED on purpose: carrying them whole would import the
    # CFG-515 token problem into every parent session. The parent needs enough to
    # tell the user a child has mail, not the full item.
    _REGISTRY="$CONFIG_REPO/registry.md"
    if [ -f "$_REGISTRY" ]; then
        _CHILDREN=$(sed -n '/^## Projects/,/^## [^P]/p' "$_REGISTRY" 2>/dev/null \
            | awk -F'|' -v parent="$PROJECT_NAME" '
                NF > 3 {
                    name = $2; par = $4
                    gsub(/^[ \t]+|[ \t]+$/, "", name)
                    gsub(/^[ \t]+|[ \t]+$/, "", par)
                    if (name == "" || name == "Project") next
                    if (name ~ /^-+$/) next
                    if (tolower(par) == tolower(parent)) print name
                }' 2>/dev/null || true)
        _CHILD_MSG=""
        while IFS= read -r _child; do
            [ -n "$_child" ] || continue
            _citems=$(grep -i -- "- \[ \].*\*\*[[:space:]]*$_child[[:space:]]*\*\*" "$INBOX" 2>/dev/null || true)
            [ -n "$_citems" ] || continue
            # grep -c exits 1 on zero matches, and `|| echo 0` would then append a
            # SECOND "0" to grep's own "0" — the two-value bug that has bitten this
            # repo before. _citems is non-empty here by construction, so the count
            # is always >= 1; head -1 makes that safe rather than merely true today.
            _ccount=$(printf '%s\n' "$_citems" | grep -c -- '- \[ \]' 2>/dev/null | head -1)
            [ -n "$_ccount" ] || _ccount=1
            _cbrief=$(printf '%s\n' "$_citems" | cut -c1-220 | tr '\n' '~' | sed 's/~/ … /g')
            _CHILD_MSG="${_CHILD_MSG:+$_CHILD_MSG | }$_child ($_ccount item(s)): $_cbrief"
        done <<EOF
$_CHILDREN
EOF
        if [ -n "$_CHILD_MSG" ]; then
            INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }INBOX TASKS for CHILD project(s) — report these to the user but do NOT delete them; each child's own session promotes and clears its own items: $_CHILD_MSG"
        fi
    fi

    # Check 3.2b (CFG-483): a tag that matches no registered project under any
    # casing is undeliverable. Case-folding alone would have hidden the casing
    # incident again the moment someone typo'd a tag — so make it loud.
    # Legitimate tag forms that must NOT warn: a machine qualifier (`proj (WSL)`),
    # several projects in one tag (`alpha + beta`), parent/child notation
    # (`parent/child`), and the reserved `new-project` placeholder.
    REGISTRY="$CONFIG_REPO/registry.md"
    if [ -f "$REGISTRY" ]; then
        # Drop the table header and separator rows — otherwise "project" and
        # "---------" register as valid project names and silently whitelist
        # a tag of that name.
        KNOWN_PROJECTS=$(sed -n '/^## Projects/,/^## [^P]/p' "$REGISTRY" \
            | sed -n 's/^| *\([A-Za-z0-9._/-]\+\) *|.*/\1/p' \
            | grep -vxE '\-+|Project' \
            | tr '[:upper:]' '[:lower:]' | sort -u)
        UNKNOWN_TAGS=""
        if [ -n "$KNOWN_PROJECTS" ]; then
            INBOX_TAGS=$(grep -o '^\- \[ \] \*\*[^*]*\*\*' "$INBOX" 2>/dev/null \
                | sed -e 's/^\- \[ \] \*\*//' -e 's/\*\*$//' -e 's/ *(.*//' \
                | tr '+' '\n' \
                | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                | tr '[:upper:]' '[:lower:]' | grep -v '^$' | sort -u)
            while IFS= read -r _tag; do
                [ -n "$_tag" ] || continue
                [ "$_tag" = "new-project" ] && continue
                printf '%s\n' "$KNOWN_PROJECTS" | grep -qxF "$_tag" && continue
                printf '%s\n' "$KNOWN_PROJECTS" | grep -qxF "${_tag##*/}" && continue
                UNKNOWN_TAGS="${UNKNOWN_TAGS:+$UNKNOWN_TAGS, }$_tag"
            done <<EOF
$INBOX_TAGS
EOF
        fi
        if [ -n "$UNKNOWN_TAGS" ]; then
            WARNINGS="${WARNINGS:+$WARNINGS | }INBOX_UNKNOWN_TAG: inbox items are tagged for project(s) that match nothing in registry.md under any casing: $UNKNOWN_TAGS — these will never be delivered. Fix the tag or register the project."
        fi
    fi

    # Check 3.2c (CFG-515): bound the inbox. Check 3.2 deliberately reports only a count
    # so no session pays the file's context cost — which also means unbounded growth emits
    # the same signal at 3 items as at 288. It reached 288 items / ~121k tokens, oldest
    # 2026-04-28, and no session was ever told that was abnormal. A raw count is not a
    # signal; a threshold is. Same shape as 3.2b: make the failure loud.
    # NOTE: stdout here is a JSON contract (CFG-503) — warnings go to $WARNINGS, never echo.
    # CFG-542: the corpus is now inbox.md PLUS every per-project file, so measure both
    # or the ceiling silently stops seeing the items that moved.
    _inbox_bytes=$(cat "$INBOX" "$CONFIG_REPO"/cross-project/inbox/*.md 2>/dev/null | wc -c 2>/dev/null || echo 0)
    [ -n "$_inbox_bytes" ] || _inbox_bytes=0
    _inbox_tok=$(( _inbox_bytes / 4 ))
    if [ "$_inbox_tok" -gt "${INBOX_TOKEN_CEILING:-20000}" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }INBOX_OVERSIZE: cross-project/inbox.md is ~${_inbox_tok} tokens (ceiling ${INBOX_TOKEN_CEILING:-20000}) across $TOTAL open item(s) — promote them into project backlogs and delete them. See CFG-515."
    fi
    # CFG-65: stream the corpus rather than naming files. As awk operands, an unmatched
    # inbox/*.md glob made gawk abort before END and `|| echo 0` hid it, so the check was
    # dead on every machine without inbox/; and the legacy preamble's dated prose counted.
    _inbox_old=$( { if command -v inbox_legacy_body >/dev/null 2>&1; then inbox_legacy_body; else cat "$INBOX"; fi
                    cat "$CONFIG_REPO"/cross-project/inbox/*.md; } 2>/dev/null \
        | awk -v cutoff="$(date -d '30 days ago' +%Y-%m-%d 2>/dev/null || echo 0000-00-00)" \
        'match($0, /20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
            d = substr($0, RSTART, RLENGTH); if (d < cutoff) n++
         } END { print n+0 }' 2>/dev/null || echo 0)
    [ -n "$_inbox_old" ] || _inbox_old=0
    if [ "$_inbox_old" -gt 0 ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }INBOX_STALE: $_inbox_old inbox line(s) carry a date older than 30 days — an inbox item that survives a month was never a handoff, it is untracked work. Promote to a backlog and delete."
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
