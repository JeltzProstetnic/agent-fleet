#!/usr/bin/env bash
# clean-pending-files.sh — List and triage pending files with backlog cross-check
# Usage: clean-pending-files.sh [--list] [--stale-only] [--project-dir <dir>]
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
PROJECT_DIR="$(pwd)"
MODE="list"
STALE_ONLY=false
STALE_THRESHOLD_DAYS=2

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)       MODE="list"; shift ;;
        --stale-only) STALE_ONLY=true; shift ;;
        --project-dir) PROJECT_DIR="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: clean-pending-files.sh [--list] [--stale-only] [--project-dir <dir>]"
            echo "  --list         List all pending files with status (default)"
            echo "  --stale-only   Only show files older than ${STALE_THRESHOLD_DAYS} days"
            echo "  --project-dir  Project directory (default: cwd)"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

DOCS_DIR="$PROJECT_DIR/docs"
BACKLOG_FILE="$PROJECT_DIR/backlog.md"

# ── Collect pending files ────────────────────────────────────────────────────
shopt -s nullglob
PENDING_FILES=("$DOCS_DIR"/pending-*.md)
shopt -u nullglob

if [[ ${#PENDING_FILES[@]} -eq 0 ]]; then
    echo "No pending files found in $DOCS_DIR"
    exit 0
fi

# ── Process and display ─────────────────────────────────────────────────────
TOTAL=0
TRACKED=0
UNTRACKED=0
STALE=0

printf "%-45s %5s  %s\n" "File" "Age" "Status"
printf "%-45s %5s  %s\n" "----" "---" "------"

for pf in "${PENDING_FILES[@]}"; do
    PF_BASE="$(basename "$pf")"
    FILE_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$pf" 2>/dev/null || echo "$(date +%s)") ) / 86400 ))

    if $STALE_ONLY && [[ $FILE_AGE_DAYS -lt $STALE_THRESHOLD_DAYS ]]; then
        continue
    fi

    # Cross-check against backlog
    STATUS="untracked"
    if [[ -f "$BACKLOG_FILE" ]] && grep -q "$PF_BASE" "$BACKLOG_FILE" 2>/dev/null; then
        STATUS="tracked"
        ((TRACKED++)) || true
    else
        ((UNTRACKED++)) || true
    fi

    if [[ $FILE_AGE_DAYS -ge $STALE_THRESHOLD_DAYS ]]; then
        ((STALE++)) || true
    fi

    ((TOTAL++)) || true
    printf "%-45s %4dd  %s\n" "$PF_BASE" "$FILE_AGE_DAYS" "$STATUS"
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "$TOTAL pending file(s): $TRACKED tracked in backlog, $UNTRACKED untracked, $STALE stale (>=${STALE_THRESHOLD_DAYS}d)"
if [[ $UNTRACKED -gt 0 ]]; then
    echo "Action needed: promote untracked files to backlog or delete them."
fi
