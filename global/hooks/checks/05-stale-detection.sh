#!/usr/bin/env bash
# Check group 5: Stale file detection — tmp docs, mobile, stale pending files, inbox staleness
# Checks: 5.1, 5.2, 5.3, 5.4
# Shared vars used: CONFIG_REPO, WARNINGS, DEFAULT_BRANCH

# Check 5.1: Scan project tmp/ dirs for documents that should be in DMS
DOC_IN_TMP=""
for tmpdir in "$HOME"/*/tmp; do
    [ -d "$tmpdir" ] || continue
    FOUND=$(find "$tmpdir" -maxdepth 2 -type f \( -name "*.md" -o -name "*.pdf" -o -name "*.docx" -o -name "*.html" -o -name "*.txt" \) 2>/dev/null | head -5)
    if [ -n "$FOUND" ]; then
        COUNT=$(echo "$FOUND" | wc -l)
        _tmp_entry="$tmpdir ($COUNT files)"
        _proj_dir="$(dirname "$tmpdir")"
        if [ -d "$_proj_dir/.git" ]; then
            _behind=$(git -C "$_proj_dir" rev-list --count HEAD..@{u} 2>/dev/null || echo "0")
            if [ "$_behind" -gt 0 ]; then
                _tmp_entry="$_tmp_entry [repo behind remote — pull may resolve]"
            fi
        fi
        DOC_IN_TMP="${DOC_IN_TMP:+$DOC_IN_TMP, }$_tmp_entry"
    fi
done
if [ -n "$DOC_IN_TMP" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }Documents found in project tmp/ dirs: $DOC_IN_TMP — these should be in DMS/NAS/Dropbox for cross-machine access."
fi

# Check 5.2: Warn if agent-fleet-mobile is not cloned (mobile data won't sync)
if grep -q 'mobile-collect\|mobile_collect' "$CONFIG_REPO/sync.sh" 2>/dev/null; then
    if [ ! -d "${USER_HOME:-$HOME}/agent-fleet-mobile" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }agent-fleet-mobile not cloned — mobile session data will not be synced."
    fi
fi

# Check 5.3: Warn on stale pending files with severity-differentiated tags
STALE_MSG=""
if [ -d "$CONFIG_REPO/docs" ]; then
    BACKLOG_FILE="$CONFIG_REPO/backlog.md"
    for pf in "$CONFIG_REPO"/docs/pending-*.md; do
        [ -f "$pf" ] || continue
        PF_BASE="$(basename "$pf")"
        FILE_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$pf" 2>/dev/null || echo "$(date +%s)") ) / 86400 ))
        # Accept BOTH header forms (CFG-482) — see 06a-session-state.sh.
        _action=$(head -5 "$pf" | sed -e 's/<!--//' -e 's/-->//' \
            | sed -n 's/^[[:space:]]*Action:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
            | head -1 | tr '[:upper:]' '[:lower:]')

        if [ "$_action" = "act" ] && [ "$FILE_AGE_DAYS" -ge 3 ]; then
            STALE_MSG="${STALE_MSG:+$STALE_MSG | }STALE_ACT: $PF_BASE (${FILE_AGE_DAYS}d) — should have been executed immediately"
        fi

        if [ "$_action" = "defer" ] && [ "$FILE_AGE_DAYS" -ge 14 ]; then
            if [ ! -f "$BACKLOG_FILE" ] || ! grep -q "$PF_BASE" "$BACKLOG_FILE" 2>/dev/null; then
                STALE_MSG="${STALE_MSG:+$STALE_MSG | }STALE_DEFER: $PF_BASE (${FILE_AGE_DAYS}d, untracked) — needs backlog item or deletion"
            fi
        fi

        if [ "$_action" = "await-user-decision" ]; then
            _await_warned=0
            if [ "$FILE_AGE_DAYS" -ge 7 ]; then
                STALE_MSG="${STALE_MSG:+$STALE_MSG | }STALE_AWAIT: $PF_BASE (${FILE_AGE_DAYS}d) — user needs a nudge"
                _await_warned=1
            fi
            if [ "$_await_warned" -eq 0 ] && [ -f "$BACKLOG_FILE" ]; then
                _refs=$(grep "$PF_BASE" "$BACKLOG_FILE" 2>/dev/null || true)
                if [ -n "$_refs" ]; then
                    _has_open=$(echo "$_refs" | grep '\- \[ \]' || true)
                    if [ -z "$_has_open" ] && echo "$_refs" | grep -q '\- \[x\]'; then
                        STALE_MSG="${STALE_MSG:+$STALE_MSG | }STALE_AWAIT: $PF_BASE — all backlog items completed, safe to delete"
                    fi
                fi
            fi
        fi

        if [ "$FILE_AGE_DAYS" -ge 2 ]; then
            # Check if file is tracked: either filename in backlog OR Tracked-by header in file
            _is_tracked=0
            if [ -f "$BACKLOG_FILE" ] && grep -q "$PF_BASE" "$BACKLOG_FILE" 2>/dev/null; then
                _is_tracked=1
            fi
            # Accept BOTH header forms (CFG-496). Every real pending file writes
            # the HTML-comment form; the bare form only ever existed in a fixture,
            # so all six tracked files were reported "no backlog item" every session.
            _tracked_by=""
            if [ "$_is_tracked" -eq 0 ]; then
                _tracked_by=$(head -5 "$pf" \
                    | sed -n -e 's/^[[:space:]]*<!--[[:space:]]*Tracked-by:[[:space:]]*\(.*\)[[:space:]]*-->.*/\1/p' \
                             -e 's/^Tracked-by:[[:space:]]*\(.*\)/\1/p' \
                    | head -1)
                if [ -n "$_tracked_by" ]; then
                    _is_tracked=1
                fi
            fi
            if [ "$_is_tracked" -eq 0 ]; then
                if ! echo "$STALE_MSG" | grep -q "$PF_BASE" 2>/dev/null; then
                    STALE_MSG="${STALE_MSG:+$STALE_MSG | }Stale pending files: $PF_BASE (${FILE_AGE_DAYS}d, no backlog item)"
                fi
            elif [ -n "$_tracked_by" ] && [ -f "$BACKLOG_FILE" ]; then
                # Tracked and old is normal. The actionable case is a file whose
                # every tracked item has closed — the convention says delete it.
                _any_open=0; _any_found=0
                for _id in $(echo "$_tracked_by" | tr ',' ' '); do
                    _id=$(echo "$_id" | tr -d '[:space:]')
                    [ -z "$_id" ] && continue
                    _row=$(grep -m1 -- "\`$_id\`" "$BACKLOG_FILE" 2>/dev/null || true)
                    [ -z "$_row" ] && continue
                    _any_found=1
                    echo "$_row" | grep -q '^- \[x\]' || _any_open=1
                done
                if [ "$_any_found" -eq 1 ] && [ "$_any_open" -eq 0 ]; then
                    if ! echo "$STALE_MSG" | grep -q "$PF_BASE" 2>/dev/null; then
                        STALE_MSG="${STALE_MSG:+$STALE_MSG | }Stale pending files: $PF_BASE — all tracked items closed, safe to delete"
                    fi
                fi
            fi
        fi
    done
fi
if [ -n "$STALE_MSG" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }$STALE_MSG"
fi

# Check 5.4: Inbox staleness — warn if 3+ items >7d, escalate if any >14d (CFG-243)
INBOX_FILE="$CONFIG_REPO/cross-project/inbox.md"
if [ -f "$INBOX_FILE" ]; then
    _inbox_stale_count=0
    _inbox_escalate_count=0
    _inbox_oldest=""
    _today_epoch=$(date +%s)
    while IFS= read -r _line; do
        # Only count unchecked items: - [ ]
        case "$_line" in *"- [ ]"*) ;; *) continue ;; esac
        # Extract date from Source:...YYYY-MM-DD or trailing YYYY-MM-DD
        _item_date=$(echo "$_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1)
        [ -z "$_item_date" ] && continue
        _item_epoch=$(date -d "$_item_date" +%s 2>/dev/null || date -jf "%Y-%m-%d" "$_item_date" +%s 2>/dev/null) || continue
        _age_days=$(( (_today_epoch - _item_epoch) / 86400 ))
        if [ "$_age_days" -gt 14 ]; then
            _inbox_stale_count=$((_inbox_stale_count + 1))
            _inbox_escalate_count=$((_inbox_escalate_count + 1))
        elif [ "$_age_days" -gt 7 ]; then
            _inbox_stale_count=$((_inbox_stale_count + 1))
        fi
        if [ "$_age_days" -gt 7 ]; then
            if [ -z "$_inbox_oldest" ] || [ "$_item_date" \< "$_inbox_oldest" ]; then
                _inbox_oldest="$_item_date"
            fi
        fi
    done < "$INBOX_FILE"
    if [ "$_inbox_stale_count" -ge 3 ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }[WARN] Cross-project inbox: $_inbox_stale_count items older than 7 days (oldest: $_inbox_oldest)"
    fi
    if [ "$_inbox_escalate_count" -gt 0 ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }[ESCALATE] Cross-project inbox: $_inbox_escalate_count items older than 14 days — promote to project backlogs or delete"
    fi
fi
