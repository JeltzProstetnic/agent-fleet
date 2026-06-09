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
#   --stale-check  Print STALE: lines for act/present files whose work shipped
#                  (all Tracked-by PRNs closed, or session-log/git shows shipped).
#                  Advisory only — never deletes, edits, or blocks. Always exit 0.
#   --demote-check --since <ref>
#                  Print DEMOTE: lines for act/present files whose Tracked-by PRN
#                  was committed since <ref>, or whose filename is cited in a
#                  commit body since <ref>. Advisory only. Always exit 0.
#   --dry-run      Show what would happen without making changes
set -euo pipefail

# Portable stat: modification time (epoch seconds) — works on GNU and macOS/BSD
_stat_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# ── Defaults ─────────────────────────────────────────────────────────────────
PROJECT_DIR="$(pwd)"
MODE=""
AUTO_PROMOTE=false
AUTO_CLEAN=false
STALE_CHECK=false
DEMOTE_CHECK=false
DEMOTE_SINCE=""
DRY_RUN=false
PROMOTE_THRESHOLD_DAYS=14
STALE_THRESHOLD_DAYS=2

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        report)         MODE="report"; shift ;;
        --auto-promote) AUTO_PROMOTE=true; shift ;;
        --auto-clean)   AUTO_CLEAN=true; shift ;;
        --stale-check)  STALE_CHECK=true; shift ;;
        --demote-check) DEMOTE_CHECK=true; shift ;;
        --since)        DEMOTE_SINCE="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --project-dir)  PROJECT_DIR="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: manage-pending.sh report [--project-dir <dir>]"
            echo "       manage-pending.sh [--auto-promote] [--auto-clean] [--dry-run] [--project-dir <dir>]"
            echo "       manage-pending.sh --stale-check [--project-dir <dir>]"
            echo "       manage-pending.sh --demote-check --since <ref> [--project-dir <dir>]"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Default to report if no mode/flags given
if [[ -z "$MODE" ]] && ! $AUTO_PROMOTE && ! $AUTO_CLEAN && ! $STALE_CHECK && ! $DEMOTE_CHECK; then
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
    mtime=$(_stat_mtime "$file" 2>/dev/null || echo "$(date +%s)")
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

# ── Reconciliation helpers (stale-check / demote-check) ───────────────────────

# Extract REAL Tracked-by PRN tokens from a pending file.
# Drops placeholders: literal "PRN-NNNN", or any Tracked-by line containing a
# parenthetical placeholder ("(file ", "(this file", "per fix", "when user assigns").
# Returns space-separated real PRN tokens (possibly empty).
get_tracked_prns() {
    local file="$1"
    local line
    line=$(grep -iE '^Tracked-by:' "$file" 2>/dev/null || true)
    [[ -z "$line" ]] && return 0
    # Placeholder lines yield no real PRNs.
    if echo "$line" | grep -qiE '\(file |\(this file|per fix|when user assigns'; then
        return 0
    fi
    local tok out=""
    for tok in $(echo "$line" | grep -oE '[A-Z]+-[0-9]+' 2>/dev/null || true); do
        [[ "$tok" == "PRN-NNNN" ]] && continue
        out="${out:+$out }$tok"
    done
    echo "$out"
}

# True only if EVERY PRN appears in a backlog line that is "- [x]" AND contains
# that PRN token in backticks. Any missing or open/in-progress PRN → false.
all_prns_closed() {
    local prns="$1"
    [[ -z "$prns" ]] && return 1
    [[ -f "$BACKLOG_FILE" ]] || return 1
    local prn
    for prn in $prns; do
        grep -E '^- \[x\]' "$BACKLOG_FILE" 2>/dev/null | grep -qF "\`$prn\`" || return 1
    done
    return 0
}

# Derive search keywords from a pending filename: strip 'pending-' prefix, '.md'
# suffix, a trailing date (-YYYYMMDD or -YYYY-MM-DD), split on '-', drop tokens
# shorter than 4 chars. Returns space-separated keywords (possibly empty).
slug_keywords() {
    local file="$1"
    local slug
    slug=$(basename "$file")
    slug="${slug#pending-}"
    slug="${slug%.md}"
    slug=$(echo "$slug" | sed -E 's/-[0-9]{8}$//; s/-[0-9]{4}-[0-9]{2}-[0-9]{2}$//')
    local tok out=""
    for tok in ${slug//-/ }; do
        [[ ${#tok} -lt 4 ]] && continue
        out="${out:+$out }$tok"
    done
    echo "$out"
}

# True if session-log.md contains a line with any slug keyword AND a shipped
# marker (shipped|commit <7-hex>|deployed). Missing file → false.
shipped_in_session_log() {
    local file="$1"
    local log="$PROJECT_DIR/docs/session-log.md"
    [[ -f "$log" ]] || return 1
    local kws
    kws=$(slug_keywords "$file")
    [[ -z "$kws" ]] && return 1
    local kw
    for kw in $kws; do
        if grep -iE "$kw.*(shipped|commit [0-9a-f]{7}|deployed)" "$log" 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    return 1
}

# True if any commit mentioning <filename> has a subject starting feat/fix, OR a
# commit body cites the exact filename. Missing .git → false.
cited_in_feat_fix_commit() {
    local file="$1"
    local fname
    fname=$(basename "$file")
    [[ -d "$PROJECT_DIR/.git" ]] || return 1
    # Subject starts with feat/fix among commits that grep-match the filename
    local subjects
    subjects=$(git -C "$PROJECT_DIR" log --all --grep "$fname" --pretty='%s' 2>/dev/null || true)
    if echo "$subjects" | grep -qE '^(feat|fix)'; then
        return 0
    fi
    # Body cites the exact filename
    local bodies
    bodies=$(git -C "$PROJECT_DIR" log --all --grep "$fname" --pretty='%b' 2>/dev/null || true)
    if echo "$bodies" | grep -qF "$fname"; then
        return 0
    fi
    return 1
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
    # Reconciliation reporters emit nothing when there are no pending files.
    if $STALE_CHECK || $DEMOTE_CHECK; then
        exit 0
    fi
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

# ── Stale-check (advisory; never deletes/edits/blocks; always exit 0) ──────────
if $STALE_CHECK; then
    for pf in "${PENDING_FILES[@]}"; do
        pf_base="$(basename "$pf")"
        action=$(get_action "$pf")
        # Only act/present files are reconciled.
        [[ "$action" != "act" && "$action" != "present" ]] && continue

        prns=$(get_tracked_prns "$pf")
        # Signal 1: every real Tracked-by PRN is closed.
        if [[ -n "$prns" ]] && all_prns_closed "$prns"; then
            echo "STALE: $pf_base (all PRNs closed)"
            continue
        fi
        # Signal 2: session-log or git shows the work shipped.
        if shipped_in_session_log "$pf" || cited_in_feat_fix_commit "$pf"; then
            echo "STALE: $pf_base (session-log/git shows shipped)"
            continue
        fi
        # else CLEAN — emit nothing.
    done
    exit 0
fi

# ── Demote-check (advisory; never deletes/edits/blocks; always exit 0) ─────────
if $DEMOTE_CHECK; then
    # Collect committed PRN tokens and cited pending-*.md filenames since <ref>.
    _committed=""
    if [[ -n "$DEMOTE_SINCE" && -d "$PROJECT_DIR/.git" ]]; then
        _committed=$(git -C "$PROJECT_DIR" log "${DEMOTE_SINCE}..HEAD" --pretty='%H %s%n%b' 2>/dev/null || true)
    fi
    _committed_prns=$(echo "$_committed" | grep -oE '[A-Z]+-[0-9]+' 2>/dev/null | sort -u || true)
    _cited_files=$(echo "$_committed" | grep -oE 'pending-[A-Za-z0-9._-]+\.md' 2>/dev/null | sort -u || true)

    for pf in "${PENDING_FILES[@]}"; do
        pf_base="$(basename "$pf")"
        action=$(get_action "$pf")
        [[ "$action" != "act" && "$action" != "present" ]] && continue

        # Filename cited in a commit body/subject since <ref>?
        if echo "$_cited_files" | grep -qFx "$pf_base"; then
            echo "DEMOTE: $pf_base (cited in a commit since $DEMOTE_SINCE)"
            continue
        fi
        # Any real Tracked-by PRN committed since <ref>?
        prns=$(get_tracked_prns "$pf")
        _hit=""
        for prn in $prns; do
            if echo "$_committed_prns" | grep -qFx "$prn"; then
                _hit="$prn"
                break
            fi
        done
        if [[ -n "$_hit" ]]; then
            echo "DEMOTE: $pf_base ($_hit shipped since $DEMOTE_SINCE)"
            continue
        fi
    done
    exit 0
fi
