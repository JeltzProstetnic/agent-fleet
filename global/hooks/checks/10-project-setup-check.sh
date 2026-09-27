#!/usr/bin/env bash
# Check group 10: Incomplete project setup detection
# Detects a project CLAUDE.md missing key sections and files ONE open "Complete project
# setup" item in the project's backlog.md (CFG-574). Warning every startup, forever, lost
# to the user's request every time and never became tracked work — against the fleet's
# "auto-fix over warn in hooks" rule. Now: file the item (idempotent), announce it once,
# and fall back to the old warning only when the backlog cannot be written.
# Shared vars used: PROJECT_DIR, WARNINGS

# Find CLAUDE.md (check .claude/ first, then root)
_PROJECT_CLAUDE=""
if [ -f "$PROJECT_DIR/.claude/CLAUDE.md" ]; then
    _PROJECT_CLAUDE="$PROJECT_DIR/.claude/CLAUDE.md"
elif [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
    _PROJECT_CLAUDE="$PROJECT_DIR/CLAUDE.md"
fi

# _ps_file_item <backlog> <issues> — echo the new item's ID (empty when the backlog uses
# none); non-zero on failure.
_ps_file_item() {
    local bl="$1" issues="$2" prefix="" num="" id="" item tmp
    if [ -f "$bl" ]; then
        # Next free ID under the backlog's dominant prefix, padded like the widest existing one.
        # The prefix is judged on the ID each ITEM opens with — a young backlog may cite
        # another project's IDs (`CFG-512`) more often than it has items of its own — and
        # only falls back to every ID in the file when no item carries one.
        prefix=$(sed -nE 's/^[[:space:]]*[-*] \[[^]]*\][^`]*`([A-Z][A-Z0-9]{1,4})-[0-9]+`.*/\1/p' "$bl" 2>/dev/null \
            | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
        [ -n "$prefix" ] || prefix=$(grep -oE '`[A-Z][A-Z0-9]{1,4}-[0-9]+`' "$bl" 2>/dev/null | tr -d '`' \
            | sed 's/-[0-9]*$//' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
        if [ -n "$prefix" ]; then
            # The number is what follows the last '-': `S3-12` is 12, not 312.
            num=$(grep -oE "\`$prefix-[0-9]+\`" "$bl" | sed -E 's/.*-([0-9]+)`$/\1/' | sort -n | tail -1)
            id=$(printf "%s-%0${#num}d" "$prefix" "$((10#$num + 1))")
        fi
    elif [ ! -e "$bl" ]; then
        printf '# Backlog — %s\n\n## Open\n\n' "$(basename "$PROJECT_DIR")" > "$bl" 2>/dev/null || return 1
    fi
    [ -f "$bl" ] && [ -w "$bl" ] || return 1
    item="- [ ] [P1] ${id:+\`$id\` }**Complete project setup**: the project CLAUDE.md is incomplete (${issues}). Load \`foundation/project-setup.md\` and finish setup — an incomplete manifest re-triggers setup regardless of project age. Filed by \`10-project-setup-check.sh\` (CFG-574)."
    tmp=$(mktemp "${TMPDIR:-/tmp}/ps-backlog.XXXXXX" 2>/dev/null) || return 1
    # Right under "## Open" when there is one, else at the end.
    awk -v item="$item" '
        { print }
        !done && /^## Open[[:space:]]*$/ { getline nxt; if (nxt != "") { print ""; print item; print nxt } else { print nxt; print item }; done = 1 }
        END { if (!done) { print ""; print item } }
    ' "$bl" > "$tmp" && cat "$tmp" > "$bl" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    printf '%s' "$id"
}

if [ -n "$_PROJECT_CLAUDE" ]; then
    _setup_issues=""
    _line_count=$(wc -l < "$_PROJECT_CLAUDE" 2>/dev/null || echo "0")

    grep -qi "## .*Roster" "$_PROJECT_CLAUDE" 2>/dev/null || _setup_issues="${_setup_issues}missing Roster, "
    grep -qi "## Reference" "$_PROJECT_CLAUDE" 2>/dev/null || _setup_issues="${_setup_issues}missing Reference, "
    grep -qi "## Project Structure\|## Structure" "$_PROJECT_CLAUDE" 2>/dev/null \
        || _setup_issues="${_setup_issues}missing Project Structure, "
    # Properly set up projects have 40+ lines
    [ "$_line_count" -lt 40 ] && _setup_issues="${_setup_issues}only ${_line_count} lines (expect 40+), "

    if [ -n "$_setup_issues" ]; then
        _setup_issues=$(echo "$_setup_issues" | sed 's/, $//')
        _ps_backlog="$PROJECT_DIR/backlog.md"
        # Only a project repo's own root gets a backlog written: never $HOME (a session
        # there finds the GLOBAL ~/.claude/CLAUDE.md) and never the read-only mobile repo.
        _ps_fixable=0
        _ps_root=$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)
        [ "$_ps_root" != "$(cd "$HOME" 2>/dev/null && pwd -P)" ] && [ ! -f "$PROJECT_DIR/.mobile-repo" ] \
            && [ "$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)" = "$_ps_root" ] && _ps_fixable=1
        if [ -f "$_ps_backlog" ] && grep -qE '^- \[[ >?]\] .*Complete project setup' "$_ps_backlog" 2>/dev/null; then
            :   # already tracked — stay silent
        elif [ "$_ps_fixable" -eq 1 ] && _ps_id=$(_ps_file_item "$_ps_backlog" "$_setup_issues"); then
            if [ -n "$_ps_id" ]; then _ps_where="as backlog item $_ps_id"; else _ps_where="in backlog.md"; fi
            WARNINGS="${WARNINGS:+$WARNINGS | }PROJECT SETUP INCOMPLETE: ${_setup_issues}. Filed ${_ps_where} (Complete project setup)."
        else
            WARNINGS="${WARNINGS:+$WARNINGS | }PROJECT SETUP INCOMPLETE: ${_setup_issues}. Load foundation/project-setup.md and complete setup before starting work."
        fi
    fi
fi
