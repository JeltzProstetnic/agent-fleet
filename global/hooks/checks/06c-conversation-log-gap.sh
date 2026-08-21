#!/usr/bin/env bash
# Check group 6c: Conversation log gap detection
# Checks: 6c.1
# Shared vars used: PROJECT_DIR, WARNINGS
#
# Soft check: warns when docs/conversation-log.md exists but lags the HEAD
# commit's "Session NNN:" subject by 2 or more sessions. Projects without a
# conversation-log.md are silently skipped.

# Check 6c.1: conversation-log.md session-number gap vs HEAD commit
_conv_log="$PROJECT_DIR/docs/conversation-log.md"
if [ -f "$_conv_log" ] && [ -d "$PROJECT_DIR/.git" ]; then
    # Match 2- or 3-hash "## Session N" / "### Session N" — both depths occur in practice
    # and take the MAX number, not the first — logs may carry a newest-first index
    # block above a forward-chron body, so the first heading isn't the highest.
    _log_last=$(grep -oE '^#{2,3} +Session +[0-9]+' "$_conv_log" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
    _commit_subject=$(git -C "$PROJECT_DIR" log -1 --format=%s 2>/dev/null)
    _commit_last=$(printf '%s' "$_commit_subject" | grep -oE '^Session [0-9]+' | grep -oE '[0-9]+')

    if [ -n "$_log_last" ] && [ -n "$_commit_last" ]; then
        _gap=$(( _commit_last - _log_last ))
        if [ "$_gap" -ge 2 ]; then
            WARNINGS="${WARNINGS:+$WARNINGS | }conversation-log.md lags by $_gap sessions (log: $_log_last, HEAD commit: $_commit_last) — ran without shutdown, backfill before continuing."
        fi
    fi
fi
