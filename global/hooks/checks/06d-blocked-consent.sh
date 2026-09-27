#!/usr/bin/env bash
# Check group 6d: Backlog items blocked on consent (CFG-695)
# Checks: 6d.1
# Shared vars used: PROJECT_DIR, WARNINGS
#
# An item parked behind a consent step nobody requests is indistinguishable
# from a dropped one: CFG-597 sat 11 days behind "blocked on Meta-Rules
# consent" with no protocol step putting it in front of MG, and recurred as
# CFG-693. This lists every OPEN item marked as needing consent, every
# session, in the WARNING channel (same as STALE_AWAIT) — a hook, not a rule,
# because a rule cannot fire where it is not loaded. 0 LLM tokens, bounded to
# one line: count + up to ten IDs.
#
# Two marker forms, both from the real backlog: the item's own line says it
# needs consent ("Rule proposal (needs Meta-Rules consent): …", "needs his
# consent because it is rule text", "→ Meta-Rules consent required"), or an
# HTML comment above a block names IDs that are "blocked on Meta-Rules
# consent". Matching keys on a NEED verb near "consent", not on the word
# alone: "verify the OAuth consent screen" and "Source: Meta-Rules consent
# flow 2026-04-22" are not the gate. Only an ID's own open line counts.

# Check 6d.1: open backlog items marked blocked-on-consent
_bc_backlog="$PROJECT_DIR/backlog.md"
if [ -f "$_bc_backlog" ]; then
    _bc_need='(need|needs|require|requires|requiring|await|awaits|awaiting|blocked[- ]on|pending|through|via|→)[^.;:]{0,30}consent|consent[- ](required|needed|pending)'
    _bc_ids=""
    _bc_lines=$(sed -E 's/consent[- ](screen|marker|gated)//g; s/\.artifact-consent//g' "$_bc_backlog" 2>/dev/null \
        | grep -iE "$_bc_need" || true)
    while IFS= read -r _bc_line; do
        [ -n "$_bc_line" ] || continue
        case "$_bc_line" in
            "- [ ]"*)
                _bc_id=$(printf '%s' "$_bc_line" | grep -oE '^- \[ \] (\[[^]]*\] )?`[A-Z]+-[0-9]+`' | grep -oE '[A-Z]+-[0-9]+' || true)
                [ -n "$_bc_id" ] && _bc_ids="$_bc_ids $_bc_id"
                ;;
            "<!--"*)
                for _bc_id in $(printf '%s' "$_bc_line" | grep -oE '[A-Z]+-[0-9]+' | sort -u); do
                    grep -qE "^- \[ \] (\[[^]]*\] )?\`$_bc_id\`" "$_bc_backlog" 2>/dev/null && _bc_ids="$_bc_ids $_bc_id"
                done
                ;;
        esac
    done <<< "$_bc_lines"
    if [ -n "$_bc_ids" ]; then
        _bc_ids=$(printf '%s\n' $_bc_ids | awk '!seen[$0]++')
        _bc_count=$(printf '%s\n' "$_bc_ids" | wc -l | tr -d ' ')
        _bc_shown=$(printf '%s\n' "$_bc_ids" | head -10 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
        _bc_more=""
        [ "$_bc_count" -gt 10 ] && _bc_more=" (+$((_bc_count - 10)) more)"
        WARNINGS="${WARNINGS:+$WARNINGS | }BLOCKED_ON_CONSENT: $_bc_count open item(s) parked on a consent nobody has asked for — $_bc_shown$_bc_more — put them to the user this session."
    fi
fi
