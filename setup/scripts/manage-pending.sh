#!/usr/bin/env bash
# manage-pending.sh — Pending file lifecycle engine
# Replaces clean-pending-files.sh with auto-promote and auto-clean capabilities.
#
# Usage:
#   manage-pending.sh report [--project-dir <dir>]
#   manage-pending.sh [--auto-promote] [--auto-clean] [--dry-run] [--project-dir <dir>]
#
# Modes:
#   report         List all pending files with action, age, backlog status
#   --auto-promote Warn on untracked defer files older than 14 days
#   --auto-clean   Delete files whose tracked backlog item(s) are all [x] done
#   --dry-run      Show what would happen without making changes
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
PROJECT_DIR="$(pwd)"
MODE=""
AUTO_PROMOTE=false
AUTO_CLEAN=false
DRY_RUN=false
PROMOTE_THRESHOLD_DAYS=14
STALE_THRESHOLD_DAYS=2

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        report)         MODE="report"; shift ;;
        --auto-promote) AUTO_PROMOTE=true; shift ;;
        --auto-clean)   AUTO_CLEAN=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --project-dir)  PROJECT_DIR="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: manage-pending.sh report [--project-dir <dir>]"
            echo "       manage-pending.sh [--auto-promote] [--auto-clean] [--dry-run] [--project-dir <dir>]"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Default to report if no mode/flags given
if [[ -z "$MODE" ]] && ! $AUTO_PROMOTE && ! $AUTO_CLEAN; then
    MODE="report"
fi

DOCS_DIR="$PROJECT_DIR/docs"
BACKLOG_FILE="$PROJECT_DIR/backlog.md"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Read Action: header from a pending file (first 5 lines), lowercase
get_action() {
    local file="$1"
    local action
    action=$(head -5 "$file" | sed -n 's/^Action: *\(.*\)/\1/p' | head -1 | tr '[:upper:]' '[:lower:]')
    echo "${action:-unknown}"
}

# Get file age in days
get_age_days() {
    local file="$1"
    local mtime
    mtime=$(stat -c %Y "$file" 2>/dev/null || echo "$(date +%s)")
    echo $(( ($(date +%s) - mtime) / 86400 ))
}

# Check if a pending file is referenced in the backlog
is_tracked() {
    local filename="$1"
    [[ -f "$BACKLOG_FILE" ]] && grep -q "$filename" "$BACKLOG_FILE" 2>/dev/null
}

# Check if ALL backlog items referencing this file are completed [x]
all_backlog_items_done() {
    local filename="$1"
    [[ -f "$BACKLOG_FILE" ]] || return 1

    # Find all lines referencing this file
    local refs
    refs=$(grep "$filename" "$BACKLOG_FILE" 2>/dev/null || true)
    [[ -z "$refs" ]] && return 1

    # Check if any referencing line is still open [ ]
    if echo "$refs" | grep -q '\- \[ \]'; then
        return 1  # At least one item is still open
    fi

    # All references are [x] (or non-checkbox lines, which we ignore)
    echo "$refs" | grep -q '\- \[x\]'
}

# ── Collect pending files ────────────────────────────────────────────────────
shopt -s nullglob
if [[ -d "$DOCS_DIR" ]]; then
    PENDING_FILES=("$DOCS_DIR"/pending-*.md)
else
    PENDING_FILES=()
fi
shopt -u nullglob

if [[ ${#PENDING_FILES[@]} -eq 0 ]]; then
    echo "No pending files found."
    exit 0
fi

# ── Report mode ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "report" ]]; then
    printf "%-45s %7s %5s  %s\n" "File" "Action" "Age" "Status"
    printf "%-45s %7s %5s  %s\n" "----" "------" "---" "------"

    total=0
    tracked=0
    untracked=0
    stale=0

    for pf in "${PENDING_FILES[@]}"; do
        pf_base="$(basename "$pf")"
        action=$(get_action "$pf")
        age=$(get_age_days "$pf")

        status="untracked"
        if is_tracked "$pf_base"; then
            status="tracked"
            ((tracked++)) || true
        else
            ((untracked++)) || true
        fi

        [[ $age -ge $STALE_THRESHOLD_DAYS ]] && ((stale++)) || true
        ((total++)) || true

        printf "%-45s %7s %4dd  %s\n" "$pf_base" "$action" "$age" "$status"
    done

    echo ""
    echo "$total pending file(s): $tracked tracked, $untracked untracked, $stale stale (>=${STALE_THRESHOLD_DAYS}d)"
    exit 0
fi

# ── Auto-promote ─────────────────────────────────────────────────────────────
if $AUTO_PROMOTE; then
    for pf in "${PENDING_FILES[@]}"; do
        pf_base="$(basename "$pf")"
        action=$(get_action "$pf")
        age=$(get_age_days "$pf")

        # Only promote defer files that are old and untracked
        [[ "$action" != "defer" ]] && continue
        [[ $age -lt $PROMOTE_THRESHOLD_DAYS ]] && continue
        is_tracked "$pf_base" && continue

        echo "PROMOTE: $pf_base (${age}d old, untracked defer) — needs backlog item"
    done
fi

# ── Auto-clean ───────────────────────────────────────────────────────────────
if $AUTO_CLEAN; then
    for pf in "${PENDING_FILES[@]}"; do
        pf_base="$(basename "$pf")"

        if all_backlog_items_done "$pf_base"; then
            if $DRY_RUN; then
                echo "CLEANED (dry-run): $pf_base — all backlog items completed"
            else
                rm "$pf"
                echo "CLEANED: $pf_base — all backlog items completed"
            fi
        fi
    done
fi
