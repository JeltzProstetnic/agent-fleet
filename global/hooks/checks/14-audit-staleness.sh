# Check group 14: Audit staleness — nudge if no lrn audit in 7+ days
# Shared vars used: INBOX_MSG
# Marker written by lrn command: ~/.claude/.last-audit-date

# Daily gate — only run once per day
_audit_gate="/tmp/.audit-stale-check-$(date +%Y-%m-%d)"
if [ ! -f "$_audit_gate" ]; then
    touch "$_audit_gate"

    _audit_marker="${HOME}/.claude/.last-audit-date"
    _audit_due=0
    _audit_days="unknown"

    if [ ! -f "$_audit_marker" ]; then
        _audit_due=1
    else
        _last_audit=$(cat "$_audit_marker" 2>/dev/null)
        if [ -n "$_last_audit" ]; then
            _last_epoch=$(date -d "$_last_audit" +%s 2>/dev/null) || _last_epoch=0
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
fi
