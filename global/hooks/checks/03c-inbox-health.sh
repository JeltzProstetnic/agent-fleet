#!/usr/bin/env bash
# Check group 3c: inbox corpus health — undeliverable tags (3.2b), unreadable per-project
# files (3.2e), corpus size and age (3.2d). Split out of 03-inbox-services.sh on
# 2026-11-25 (CFG-1091, 150-line limit); runs after 03/03b by filename order.
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX, TOTAL.
#
# Every signal here reads the WHOLE corpus through inbox-lib.sh — the per-project files
# plus the legacy spillover. Since CFG-542 these checks read inbox.md alone, which holds
# 0 open items, so they stayed silent while 63 items aged in the per-project files
# (audit 2026-11-20, CFG-1091 D1/D5).
# NOTE: stdout is a JSON contract (CFG-503) — warnings go to $WARNINGS, never echo.

_INBOX="${INBOX:-$CONFIG_REPO/cross-project/inbox.md}"
if [ -f "$_INBOX" ] || [ -d "$CONFIG_REPO/cross-project/inbox" ]; then
    if ! command -v inbox_all_items >/dev/null 2>&1; then
        _ih_lib="$CONFIG_REPO/setup/scripts/inbox-lib.sh"
        # shellcheck disable=SC1090
        [ -f "$_ih_lib" ] && . "$_ih_lib" 2>/dev/null
    fi
    # Open items of the whole corpus; an un-migrated machine without the library reads
    # the legacy file alone, as before.
    _ih_items() {
        if command -v inbox_all_items >/dev/null 2>&1; then inbox_all_items
        else grep -- '^- \[ \]' "$_INBOX" 2>/dev/null; fi
        return 0
    }

    # Check 3.2b (CFG-483): a tag that matches no live project under any casing is
    # undeliverable. Case-folding alone would have hidden the casing incident again the
    # moment someone typo'd a tag — so make it loud. Legitimate forms that must NOT warn:
    # a machine qualifier (`proj (WSL)`), several projects (`alpha + beta`), parent/child
    # notation (`parent/child`), the reserved `new-project` placeholder, and a project's
    # directory name (fleet-auditor's session runs in auditor/). A tag for a DELETED
    # project is reported with its successor (CFG-1091 D3).
    if command -v inbox_registry_live_names >/dev/null 2>&1; then
        KNOWN_PROJECTS=$( { inbox_registry_live_names; inbox_registry_live_dirnames; } 2>/dev/null | sort -u)
    elif [ -f "$CONFIG_REPO/registry.md" ]; then
        KNOWN_PROJECTS=$(sed -n '/^## Projects/,/^## [^P]/p' "$CONFIG_REPO/registry.md" \
            | sed -n 's/^| *\([A-Za-z0-9._/-]\+\) *|.*/\1/p' | grep -vxE '\-+|Project' \
            | tr '[:upper:]' '[:lower:]' | sort -u)
    else
        KNOWN_PROJECTS=""
    fi
    UNKNOWN_TAGS=""
    if [ -n "$KNOWN_PROJECTS" ]; then
        INBOX_TAGS=$(_ih_items | grep -o '^\- \[ \] \*\*[^*]*\*\*' 2>/dev/null \
            | sed -e 's/^\- \[ \] \*\*//' -e 's/\*\*$//' -e 's/ *(.*//' \
            | tr '+' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
            | tr '[:upper:]' '[:lower:]' | grep -v '^$' | sort -u)
        while IFS= read -r _tag; do
            [ -n "$_tag" ] || continue
            [ "$_tag" = "new-project" ] && continue
            printf '%s\n' "$KNOWN_PROJECTS" | grep -qxF -- "$_tag" && continue
            printf '%s\n' "$KNOWN_PROJECTS" | grep -qxF -- "${_tag##*/}" && continue
            _dead=""
            command -v inbox_registry_dead >/dev/null 2>&1 && _dead=$(inbox_registry_dead "$_tag" 2>/dev/null || true)
            if [ -n "$_dead" ]; then
                _succ="${_dead#*|}"
                _tag="$_tag (registry: ${_dead%%|*}${_succ:+ → successor $_succ})"
            fi
            UNKNOWN_TAGS="${UNKNOWN_TAGS:+$UNKNOWN_TAGS, }$_tag"
        done <<EOF
$INBOX_TAGS
EOF
    fi
    if [ -n "$UNKNOWN_TAGS" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }INBOX_UNKNOWN_TAG: inbox items are tagged for project(s) that match no live project in registry.md under any casing: $UNKNOWN_TAGS — these will never be delivered. Fix the tag (file for the successor) or register the project."
    fi

    # Check 3.2e (CFG-1091 D2): a per-project file whose name matches no live project's
    # registry name or directory is read by nobody — jasmin.md (project deleted) and
    # fleet-auditor.md (its session runs in auditor/) held mail for months with no signal.
    if command -v inbox_unreadable_files >/dev/null 2>&1; then
        _unread=$(inbox_unreadable_files 2>/dev/null | awk '{ printf "%s%s.md (%s open)", (NR > 1 ? ", " : ""), $1, $2 }')
        if [ -n "$_unread" ]; then
            WARNINGS="${WARNINGS:+$WARNINGS | }INBOX_UNREACHABLE: per-project inbox file(s) no session will ever read, because the name matches no live project's registry name or directory: $_unread. Re-file each item with inbox-file.sh --project <live project>, or register the project."
        fi
    fi

    # Check 3.2d (CFG-515): bound the inbox. Check 3.2 deliberately reports only a count
    # so no session pays the file's context cost — which also means unbounded growth emits
    # the same signal at 3 items as at 288. It reached 288 items / ~121k tokens, oldest
    # 2026-04-28, and no session was ever told that was abnormal. A raw count is not a
    # signal; a threshold is. CFG-1091 D1: the warning named inbox.md while measuring the
    # whole corpus — it now names what it measures.
    _inbox_bytes=$(cat "$_INBOX" "$CONFIG_REPO"/cross-project/inbox/*.md 2>/dev/null | wc -c 2>/dev/null || echo 0)
    [ -n "$_inbox_bytes" ] || _inbox_bytes=0
    _inbox_tok=$(( _inbox_bytes / 4 ))
    _total="${TOTAL:-}"
    [ -n "$_total" ] || _total=$(_ih_items | grep -c '^- \[ \]' 2>/dev/null | head -1)
    if [ "$_inbox_tok" -gt "${INBOX_TOKEN_CEILING:-20000}" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }INBOX_OVERSIZE: the cross-project inbox corpus (cross-project/inbox/*.md plus the legacy inbox.md spillover) is ~${_inbox_tok} tokens (ceiling ${INBOX_TOKEN_CEILING:-20000}) across ${_total:-0} open item(s) — promote them into project backlogs and delete them. See CFG-515."
    fi
    # Staleness counts OPEN items only (CFG-1091 D1): the old scan counted any dated
    # line, and 55 of its 90 "stale lines" were dispatch tombstones and prose. The
    # legacy preamble is excluded by inbox_legacy_body (CFG-65).
    _inbox_old=$(_ih_items | awk -v cutoff="$(date -d '30 days ago' +%Y-%m-%d 2>/dev/null || echo 0000-00-00)" \
        'match($0, /20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) { d = substr($0, RSTART, RLENGTH); if (d < cutoff) n++ }
         END { print n+0 }' 2>/dev/null || echo 0)
    [ -n "$_inbox_old" ] || _inbox_old=0
    if [ "$_inbox_old" -gt 0 ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }INBOX_STALE: $_inbox_old open inbox item(s) carry a date older than 30 days — an inbox item that survives a month was never a handoff, it is untracked work. Promote to a backlog and delete."
    fi
fi
