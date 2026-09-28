#!/usr/bin/env bash
# Check group 9: DMS backup gap audit (daily)
# Runs dms-stats.sh --gaps-only once per day, surfaces critical backup gaps in additionalContext.
# Counts empty Backup CELLS, not copies on disk — disk truth is dms-verify.sh (CFG-702).
# Shared vars used: CONFIG_REPO, WARNINGS

_DMS_STATS="$CONFIG_REPO/dms/scripts/dms-stats.sh"

# Daily gate via sched-lib (if available) or fallback to inline marker
_sched_lib="${CONFIG_REPO:-}/setup/scripts/sched-lib.sh"
if [ -f "$_sched_lib" ]; then
    source "$_sched_lib"
    sched_is_due "dms-backup-check" "daily" || return 0 2>/dev/null || true
else
    # fallback inline marker — never a bare /tmp (GH#13: read-only in the CC sandbox)
    _gate="${SCHED_MARKER_DIR:-${TMPDIR:-/tmp}}""/.dms-backup-check-$(date +%Y-%m-%d)"
    [ ! -f "$_gate" ] || return 0 2>/dev/null || true
    touch "$_gate" 2>/dev/null || true
fi

if [ -f "$_DMS_STATS" ]; then
    # --gaps-only: one awk pass (ms); the full report takes ~40 s and only finished
    # its gap section inside the 5 s by luck of section order (CFG-702).
    _backup_output=$(timeout 5 bash "$_DMS_STATS" --gaps-only 2>/dev/null || true)
    if [ -n "$_backup_output" ]; then
        _gap_count=$(echo "$_backup_output" | grep -c "^  WARNING:" 2>/dev/null || echo "0")
        if [ "$_gap_count" -gt 0 ]; then
            # Tier 0/1 categories first (legal, identity, financial, medical, regulatory,
            # professional — dms/README.md tiers), then creative/academic. The old
            # CRE/ACA-only filter never showed a Tier-0 gap (CFG-702).
            _critical_gaps=$( { echo "$_backup_output" | grep -E "^  WARNING: (LEG|PER|FIN|MED|REG|PRO)-" || true
                                echo "$_backup_output" | grep -E "^  WARNING: (CRE|ACA)-" || true; } \
                | head -5 | sed 's/^  WARNING: //' | tr '\n' ';' | sed 's/;$//; s/;/; /g')
            WARNINGS="${WARNINGS:+$WARNINGS | }DMS backup gaps: $_gap_count document(s) have no backup location. Critical: $_critical_gaps"
        fi
        # Mark done (sched-lib or fallback)
        if type sched_mark_done &>/dev/null; then
            sched_mark_done "dms-backup-check" "daily"
        elif [ -z "${_gate:-}" ]; then
            touch "${SCHED_MARKER_DIR:-${TMPDIR:-/tmp}}""/.dms-backup-check-$(date +%Y-%m-%d)" 2>/dev/null || true
        fi
    fi
fi
