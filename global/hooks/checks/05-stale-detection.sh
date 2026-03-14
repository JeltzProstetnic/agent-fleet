# Check group 5: Stale file detection — tmp docs, mobile, stale pending files
# Checks: 15, 16, 17
# Shared vars used: CONFIG_REPO, WARNINGS, DEFAULT_BRANCH

# Check 15: Scan project tmp/ dirs for documents that should be in DMS
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

# Check 16: Warn if agent-fleet-mobile is not cloned (mobile data won't sync)
if grep -q 'mobile-collect\|mobile_collect' "$CONFIG_REPO/sync.sh" 2>/dev/null; then
    if [ ! -d "${USER_HOME:-$HOME}/agent-fleet-mobile" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }agent-fleet-mobile not cloned — mobile session data will not be synced. Clone it from your GitHub and place at ~/agent-fleet-mobile"
    fi
fi

# Check 17: Warn on stale pending files with severity-differentiated tags
STALE_MSG=""
if [ -d "$CONFIG_REPO/docs" ]; then
    BACKLOG_FILE="$CONFIG_REPO/backlog.md"
    for pf in "$CONFIG_REPO"/docs/pending-*.md; do
        [ -f "$pf" ] || continue
        PF_BASE="$(basename "$pf")"
        FILE_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$pf" 2>/dev/null || echo "$(date +%s)") ) / 86400 ))
        _action=$(head -5 "$pf" | sed -n 's/^Action: *\(.*\)/\1/p' | head -1 | tr '[:upper:]' '[:lower:]')

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
            if [ ! -f "$BACKLOG_FILE" ] || ! grep -q "$PF_BASE" "$BACKLOG_FILE" 2>/dev/null; then
                if ! echo "$STALE_MSG" | grep -q "$PF_BASE" 2>/dev/null; then
                    STALE_MSG="${STALE_MSG:+$STALE_MSG | }Stale pending files: $PF_BASE (${FILE_AGE_DAYS}d, no backlog item)"
                fi
            fi
        fi
    done
fi
if [ -n "$STALE_MSG" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }$STALE_MSG"
fi
