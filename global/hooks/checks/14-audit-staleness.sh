#!/usr/bin/env bash
# Check group 14: Audit staleness — nudge if no lrn audit in 7+ days
# Shared vars used: INBOX_MSG
# Marker written by lrn command: ~/.claude/.last-audit-date

# Daily gate via sched-lib (if available) or fallback to inline marker
_sched_lib="${CONFIG_REPO:-}/setup/scripts/sched-lib.sh"
if [ -f "$_sched_lib" ]; then
    source "$_sched_lib"
    SCHED_MARKER_DIR="${SCHED_MARKER_DIR:-/tmp}"
    sched_is_due "audit-stale-check" "daily" || return 0 2>/dev/null || true
else
    # fallback inline marker
    _gate="/tmp/.audit-stale-check-$(date +%Y-%m-%d)"
    [ ! -f "$_gate" ] || return 0 2>/dev/null || true
    touch "$_gate"
fi

_audit_marker="${HOME}/.claude/.last-audit-date"
_audit_due=0
_audit_days="unknown"

if [ ! -f "$_audit_marker" ]; then
    _audit_due=1
else
    _last_audit=$(cat "$_audit_marker" 2>/dev/null)
    if [ -n "$_last_audit" ]; then
        _last_epoch=$(date -d "$_last_audit" +%s 2>/dev/null || date -jf "%Y-%m-%d" "$_last_audit" +%s 2>/dev/null) || _last_epoch=0
        _now_epoch=$(date +%s)
        if [ "$_last_epoch" -gt 0 ]; then
            _audit_days=$(( (_now_epoch - _last_epoch) / 86400 ))
            [ "$_audit_days" -gt 7 ] && _audit_due=1
        else
            _audit_due=1
        fi
    else
        _audit_due=1
    fi
fi

if [ "$_audit_due" -eq 1 ]; then
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }AUDIT_DUE: No lrn audit in $_audit_days days. Consider running 'lrn' for systematic triage."
fi

# Mark done (sched-lib or fallback)
if type sched_mark_done &>/dev/null; then
    sched_mark_done "audit-stale-check" "daily"
elif [ -z "${_gate:-}" ]; then
    touch "/tmp/.audit-stale-check-$(date +%Y-%m-%d)"
fi
