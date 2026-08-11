#!/usr/bin/env bash
# Check 20.1: Surface the project's User Needs document at session start.
#
# Why: the global rule "Read the User Needs before building" is a
# "before X, first read Y" pre-step — the shape that reliably fails when
# attention is on the slice rather than on an auxiliary read. This converts it
# into an in-context reminder, and costs nothing at all on the projects (most of
# them) that have no User Needs document.
#
# Informational only — this check must NEVER populate WARNINGS.
# Shared vars used: PROJECT_DIR, INBOX_MSG

if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    _un_list="$(
        find "$PROJECT_DIR" \
            \( -name .git -o -name node_modules -o -name tmp -o -name .venv \
               -o -name venv -o -name archive -o -name .serena \) -prune -o \
            -maxdepth 4 -type f -iname '*user*needs*.md' -print 2>/dev/null \
        | grep -v '/setup/templates/' \
        | grep -v '/\.claude/' \
        | sort
    )"

    if [ -n "$_un_list" ]; then
        _un_count="$(printf '%s\n' "$_un_list" | grep -c . )"

        # A copy under deliverables/ is the circulated, authoritative one;
        # anything else is a working draft. Highest sort order wins within
        # each group, so the newest dated folder / version is preferred.
        _un_pick="$(printf '%s\n' "$_un_list" | grep '/deliverables/' | tail -n 1)"
        [ -z "$_un_pick" ] && _un_pick="$(printf '%s\n' "$_un_list" | tail -n 1)"

        # Report the path relative to the project, so it is short and pasteable.
        _un_rel="${_un_pick#"$PROJECT_DIR"/}"

        _un_note="UN_PRESENT: $_un_rel"
        [ "$_un_count" -gt 1 ] && _un_note="$_un_note ($_un_count found)"
        _un_note="$_un_note — read it before implementation or other consequential work; backlog and plan shorthand are not a substitute."

        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }$_un_note"
    fi

    unset _un_list _un_count _un_pick _un_rel _un_note
fi
