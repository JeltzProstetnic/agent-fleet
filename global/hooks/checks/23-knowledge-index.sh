#!/usr/bin/env bash
# Check group 23: knowledge/INDEX.md completeness (daily) — CFG-635.
#
# The fleet's knowledge design is conditional loading, so a file that is not in
# the index is loaded only by someone who already knows its name. That defeats
# the mechanism for exactly the sessions that need it most: a new machine, a
# cold start, an emergency. The index had drifted to 31 of 49 files before
# anyone noticed, because nothing ever looked.
#
# Reports the count examined as well as the count missing, so "inspected
# nothing" is visibly distinct from "found nothing" (CFG-611).
# Shared vars used: CONFIG_REPO, WARNINGS

_ki_dir="${CONFIG_REPO:-}/global/knowledge"
_ki_index="$_ki_dir/INDEX.md"

# Not this repo — stay silent rather than warn about someone else's layout.
[ -d "$_ki_dir" ] || return 0 2>/dev/null || true

# Daily gate
_ki_gate="/tmp/.knowledge-index-check-$(date +%Y-%m-%d)"
[ ! -f "$_ki_gate" ] || return 0 2>/dev/null || true
touch "$_ki_gate" 2>/dev/null || true

_ki_total=0
_ki_missing=""
_ki_missing_n=0

for _ki_f in "$_ki_dir"/*.md; do
    [ -f "$_ki_f" ] || continue
    _ki_base="$(basename "$_ki_f")"
    [ "$_ki_base" = "INDEX.md" ] && continue
    _ki_total=$((_ki_total + 1))
    if [ -f "$_ki_index" ] && grep -qF "\`$_ki_base\`" "$_ki_index" 2>/dev/null; then
        continue
    fi
    _ki_missing="${_ki_missing:+$_ki_missing, }$_ki_base"
    _ki_missing_n=$((_ki_missing_n + 1))
done

# Stale rows: an index entry whose file is gone points a session at nothing.
_ki_stale=""
_ki_stale_n=0
if [ -f "$_ki_index" ]; then
    while IFS= read -r _ki_row; do
        [ -z "$_ki_row" ] && continue
        [ -f "$_ki_dir/$_ki_row" ] && continue
        _ki_stale="${_ki_stale:+$_ki_stale, }$_ki_row"
        _ki_stale_n=$((_ki_stale_n + 1))
    done < <(grep -oE '^\|[[:space:]]*`[a-z0-9._-]+\.md`' "$_ki_index" 2>/dev/null \
             | sed -E 's/^\|[[:space:]]*`([^`]+)`.*/\1/' | sort -u)
fi

if [ ! -f "$_ki_index" ] && [ "$_ki_total" -gt 0 ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }KNOWLEDGE_INDEX: global/knowledge/INDEX.md is MISSING while $_ki_total knowledge file(s) exist — every one of them is undiscoverable to a session that looks there (CFG-635)."
elif [ "$_ki_missing_n" -gt 0 ] || [ "$_ki_stale_n" -gt 0 ]; then
    _ki_msg="KNOWLEDGE_INDEX: examined $_ki_total knowledge file(s)."
    [ "$_ki_missing_n" -gt 0 ] && _ki_msg="$_ki_msg $_ki_missing_n of $_ki_total have no INDEX.md row and are undiscoverable: $_ki_missing."
    [ "$_ki_stale_n" -gt 0 ] && _ki_msg="$_ki_msg $_ki_stale_n INDEX row(s) point at a file that no longer exists: $_ki_stale."
    _ki_msg="$_ki_msg Fix: add the row(s) in the same commit as the file (CFG-635)."
    WARNINGS="${WARNINGS:+$WARNINGS | }$_ki_msg"
fi

unset _ki_dir _ki_index _ki_gate _ki_total _ki_missing _ki_missing_n _ki_stale _ki_stale_n _ki_f _ki_base _ki_row _ki_msg
