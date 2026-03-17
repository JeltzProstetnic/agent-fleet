# Check group 9: DMS backup gap audit (daily)
# Runs dms-stats.sh once per day, surfaces critical backup gaps in systemMessage.
# Shared vars used: CONFIG_REPO, WARNINGS

_DMS_STATS="$CONFIG_REPO/dms/scripts/dms-stats.sh"
_BACKUP_CHECK_MARKER="/tmp/.dms-backup-check-$(date +%Y%m%d)"

if [ -f "$_DMS_STATS" ] && [ ! -f "$_BACKUP_CHECK_MARKER" ]; then
    _backup_output=$(timeout 5 bash "$_DMS_STATS" 2>/dev/null || true)
    if [ -n "$_backup_output" ]; then
        _gap_count=$(echo "$_backup_output" | grep -c "^  WARNING:" 2>/dev/null || echo "0")
        if [ "$_gap_count" -gt 0 ]; then
            _critical_gaps=$(echo "$_backup_output" | grep "^  WARNING:" | head -5 | sed 's/^  WARNING: //' | tr '\n' '; ' | sed 's/; $//')
            WARNINGS="${WARNINGS:+$WARNINGS | }DMS backup gaps: $_gap_count document(s) have no backup location. Critical: $_critical_gaps"
        fi
        touch "$_BACKUP_CHECK_MARKER"
    fi
fi
