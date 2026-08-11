#!/usr/bin/env bash
# Check group 9: DMS backup gap audit (daily)
# Runs dms-stats.sh once per day, surfaces critical backup gaps in additionalContext.
# Shared vars used: CONFIG_REPO, WARNINGS

_DMS_STATS="$CONFIG_REPO/dms/scripts/dms-stats.sh"

# Daily gate via sched-lib (if available) or fallback to inline marker
_sched_lib="${CONFIG_REPO:-}/setup/scripts/sched-lib.sh"
if [ -f "$_sched_lib" ]; then
    source "$_sched_lib"
    SCHED_MARKER_DIR="${SCHED_MARKER_DIR:-/tmp}"
    sched_is_due "dms-backup-check" "daily" || return 0 2>/dev/null || true
else
    # fallback inline marker
    _gate="/tmp/.dms-backup-check-$(date +%Y-%m-%d)"
    [ ! -f "$_gate" ] || return 0 2>/dev/null || true
    touch "$_gate"
fi

if [ -f "$_DMS_STATS" ]; then
    _backup_output=$(timeout 5 bash "$_DMS_STATS" 2>/dev/null || true)
    if [ -n "$_backup_output" ]; then
        _gap_count=$(echo "$_backup_output" | grep -c "^  WARNING:" 2>/dev/null || echo "0")
        if [ "$_gap_count" -gt 0 ]; then
            # Extract creative + academic gaps (highest priority)
            _critical_gaps=$(echo "$_backup_output" | grep "^  WARNING:" | grep -E "CRE-|ACA-" | head -5 | sed 's/^  WARNING: //' | tr '\n' '; ' | sed 's/; $//')
            WARNINGS="${WARNINGS:+$WARNINGS | }DMS backup gaps: $_gap_count document(s) have no backup location. Critical: $_critical_gaps"
        fi
        # Mark done (sched-lib or fallback)
        if type sched_mark_done &>/dev/null; then
            sched_mark_done "dms-backup-check" "daily"
        elif [ -z "${_gate:-}" ]; then
            touch "/tmp/.dms-backup-check-$(date +%Y-%m-%d)"
        fi
    fi
fi
