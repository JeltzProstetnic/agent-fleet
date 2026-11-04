#!/usr/bin/env bash
# lib-pending-due.sh — the due date of a docs/pending-*.md file (CFG-896).
#
# Global CLAUDE.md sends work due on a future date into a dated docs/pending-*.md
# (plus the fleet calendar). Before CFG-896 the startup checks read every `act`
# file as "execute immediately", so scheduled work raised ACT_PENDING/STALE_ACT
# weeks early. A file cannot be created in the future, so a future date in an act
# file's name is unambiguously a due date.
#
# pending_due_date <file> — prints YYYY-MM-DD or nothing:
#   1. a "Due: YYYY-MM-DD" line in the first 5 lines (comment form or bare), else
#   2. a trailing -YYYY-MM-DD in the filename.
pending_due_date() {
    local f="$1" d
    d=$(head -5 "$f" 2>/dev/null | sed -e 's/<!--//' -e 's/-->//' \
        | sed -n 's/^[[:space:]]*Due:[[:space:]]*\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' | head -1)
    [ -n "$d" ] || d=$(basename "$f" .md | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}$' || true)
    printf '%s' "$d"
}

# pending_days_past_due <YYYY-MM-DD> — whole days from the due date to today
# (negative = still in the future). Midnight to midnight, rounded, so DST never
# shaves a day off.
pending_days_past_due() {
    local today due
    today=$(date -d "$(date +%F)" +%s 2>/dev/null) || return 1
    due=$(date -d "$1" +%s 2>/dev/null) || return 1
    local diff=$(( today - due ))
    # round to the nearest day on both sides of zero — bash division truncates toward zero
    if [ "$diff" -ge 0 ]; then echo $(( (diff + 43200) / 86400 )); else echo $(( -((43200 - diff) / 86400) )); fi
}
