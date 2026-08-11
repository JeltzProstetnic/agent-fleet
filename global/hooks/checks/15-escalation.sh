#!/usr/bin/env bash
# Check group 15: Escalation aggregation — summarize when warnings pile up
# If >3 warnings exist, prepend an ESCALATION summary for visibility.
# Shared vars used: WARNINGS
# NOTE: This check MUST be sourced LAST (numeric sort ensures this).

_warn_count=0
if [ -n "$WARNINGS" ]; then
    # Count pipe-separated warning segments
    _old_ifs="$IFS"
    IFS='|'
    for _seg in $WARNINGS; do
        _seg_trimmed="${_seg#"${_seg%%[![:space:]]*}"}"
        [ -n "$_seg_trimmed" ] && ((_warn_count++)) || true
    done
    IFS="$_old_ifs"
fi

if [ "$_warn_count" -gt 3 ]; then
    WARNINGS="ESCALATION: $_warn_count warnings — review recommended | $WARNINGS"
fi
