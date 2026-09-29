#!/usr/bin/env bash
# Check group 26: decisions.md monthly review due (CFG-637).
# Checks: 26.1
# Shared vars used: PROJECT_DIR, WARNINGS
#
# foundation/session-protocol.md Layer 3b (owner-approved 2026-09-29): review
# docs/decisions.md monthly — archive superseded or executed entries to
# docs/decisions-archive.md, compress the rest — dated by its "Last reviewed:"
# line. A monthly duty with no trigger is never done (lrn Pattern 2), so this
# check raises it mechanically at 0 tokens. A missing or unreadable date counts
# as due: the check must never read an unknown state as fresh.

_dr_file="${PROJECT_DIR:-$PWD}/docs/decisions.md"
if [ -f "$_dr_file" ]; then
    _dr_last=$(grep -m1 -E '^Last reviewed:' "$_dr_file" 2>/dev/null | sed -E 's/^Last reviewed:[[:space:]]*//; s/[[:space:]]+$//')
    _dr_epoch=""
    if [[ "$_dr_last" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        _dr_epoch=$(date -d "$_dr_last" +%s 2>/dev/null || date -jf "%Y-%m-%d" "$_dr_last" +%s 2>/dev/null) || _dr_epoch=""
    fi
    _dr_msg=""
    if [ -z "$_dr_epoch" ]; then
        _dr_msg="docs/decisions.md was never reviewed (no readable 'Last reviewed: YYYY-MM-DD' line)"
    else
        _dr_days=$(( ( $(date +%s) - _dr_epoch ) / 86400 ))
        if [ "$_dr_days" -gt 30 ]; then
            _dr_msg="docs/decisions.md last reviewed $_dr_last ($_dr_days days ago)"
        fi
    fi
    if [ -n "$_dr_msg" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }DECISIONS_REVIEW_DUE: $_dr_msg — monthly review (session-protocol Layer 3b): move superseded or executed entries verbatim to docs/decisions-archive.md, compress the rest to decision plus rationale, then set 'Last reviewed:' to today."
    fi
fi
