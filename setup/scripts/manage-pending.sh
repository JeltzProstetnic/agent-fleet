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
#   --stale-check  Print STALE: lines for act/present files whose EVERY
#                  Tracked-by ID is "- [x]" on its own backlog line, UNTRACKED:
#                  lines for act/present files with no real Tracked-by ID, and
#                  DANGLING: lines for any file whose supersession pointer names
#                  a pending file that does not exist (CFG-620). No prose is
#                  ever read as completion evidence.
#                  Advisory only — never deletes, edits, or blocks. Always exit 0.
#   --demote-check --since <ref>
#                  Print DEMOTE: lines for act/present files whose Tracked-by PRN
#                  was committed since <ref> while none of its Tracked-by IDs is
#                  still open on its own backlog line, or whose filename is cited
#                  in a commit body since <ref>. Advisory only. Always exit 0.
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

# Read Action: header from a pending file (first 5 lines), lowercase.
# Accepts BOTH `Action: x` and `<!-- Action: x -->` (CFG-482) — every real
# pending file uses the comment form so the header stays invisible in rendered
# markdown, and the bare-form-only parser reported all of them as "unknown".
get_action() {
    local file="$1"
    local action
    action=$(head -5 "$file" | sed -e 's/<!--//' -e 's/-->//' \
        | sed -n 's/^[[:space:]]*Action:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
        | head -1 | tr '[:upper:]' '[:lower:]')
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
# Accepts BOTH `Tracked-by: x` and `<!-- Tracked-by: x -->` (CFG-620): every
# real pending file writes the comment form, and the bare-form-only grep left
# all of them "untracked" — which is how the old prose heuristic got to run on
# files whose IDs were plainly open.
# Drops placeholders: literal "PRN-NNNN", or any Tracked-by line containing a
# parenthetical placeholder ("(file ", "(this file", "per fix", "when user assigns").
# Returns space-separated real PRN tokens (possibly empty).
get_tracked_prns() {
    local file="$1"
    local line
    line=$(sed -e 's/<!--//' -e 's/-->//' "$file" 2>/dev/null \
        | grep -iE '^[[:space:]]*Tracked-by:' | head -1 || true)
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

# State of ONE backlog ID, read from the line that IS that item — the ID in
# backticks right after the checkbox (and optional [Pn] tag). An ID quoted
# inside another item's text does not count: CFG-597's closed line cites
# `CFG-695`, which is open. Prints the checkbox character (" ", "x", "?", ">")
# or "missing" when this backlog has no such line (another project's ID).
prn_state() {
    local prn="$1" row
    [[ -f "$BACKLOG_FILE" ]] || { echo "missing"; return 0; }
    row=$(grep -E "^- \[.\] (\[[^]]*\] )?\`${prn}\`" "$BACKLOG_FILE" 2>/dev/null | head -1 || true)
    [[ -n "$row" ]] || { echo "missing"; return 0; }
    printf '%s\n' "${row:3:1}"
}

# True only if EVERY PRN's own line is "- [x]". Open, in-progress ([>]),
# awaiting live proof ([?]) or unresolvable here → false.
all_prns_closed() {
    local prns="$1"
    [[ -z "$prns" ]] && return 1
    [[ -f "$BACKLOG_FILE" ]] || return 1
    local prn
    for prn in $prns; do
        [[ "$(prn_state "$prn")" == "x" ]] || return 1
    done
    return 0
}

# Subjects and bodies of the commits `git log <args>` selects, as "S <subject>"
# and "B <body line>" lines — WITHOUT the SessionEnd hook's own commits (subject
# "Auto-sync: ..."). Their body lists every path the hook swept (CFG-665), so a
# live, unshipped handoff swept into one is named there; that records the sweep,
# not a shipment, and counting it hid live handoffs as demotable. (--stale-check
# reads no commit at all since CFG-620; --demote-check is the caller.)
non_sweep_log() {
    git -C "$PROJECT_DIR" log "$@" --pretty='%x1e%s%n%b' 2>/dev/null \
        | awk 'BEGIN { RS = "\036" }
               NR > 1 { n = split($0, l, "\n"); if (l[1] ~ /^Auto-sync:/) next
                        print "S " l[1]; for (i = 2; i <= n; i++) print "B " l[i] }' || true
}

# Successor pointers: a pending file that is the OBJECT of a supersession phrase
# ("SUPERSEDED … by X", "carried forward into X", "continued in X", "moved to
# X", "absorbed/folded into X", "successor: X") — X must follow the phrase
# directly (backticks, quotes, "(" and a docs/ prefix allowed). Any pending
# file named LATER on the line is not a pointer: "moved to backlog `CFG-700`;
# the old notes in pending-a.md were deleted" names a resolved predecessor.
# "Supersedes X" names a PREDECESSOR and is deliberately not matched — those
# get deleted. Prints the named files (basenames, one per line, self
# excluded), possibly nothing.
named_successors() {
    local file="$1" self
    self=$(basename "$file")
    grep -oiE "(superseded[^.]{0,40}by|carried forward[^.]{0,20}(in|into|to)|continued in|moved to|absorbed into|folded into|successor:?)[[:space:]]*[\`\"'(]*(docs/)?pending-[A-Za-z0-9._-]+\.md" "$file" 2>/dev/null \
        | grep -oE 'pending-[A-Za-z0-9._-]+\.md' \
        | grep -vFx "$self" | sort -u || true
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
# CFG-620: backlog STATE only. The former signal 2 (session-log lines matching
# "shipped|commit <hex>|deployed", feat/fix commits citing the filename) read a
# file's own prose as completion evidence and was wrong every recorded time.
if $STALE_CHECK; then
    for pf in "${PENDING_FILES[@]}"; do
        pf_base="$(basename "$pf")"
        action=$(get_action "$pf")

        # Every file, whatever its action: a supersession pointer must resolve.
        for _succ in $(named_successors "$pf"); do
            [[ -f "$DOCS_DIR/$_succ" ]] || echo "DANGLING: $pf_base → $_succ (named successor does not exist)"
        done

        # Only act/present files are reconciled against the backlog.
        [[ "$action" != "act" && "$action" != "present" ]] && continue

        prns=$(get_tracked_prns "$pf")
        if [[ -z "$prns" ]]; then
            echo "UNTRACKED: $pf_base (no Tracked-by)"
            continue
        fi
        if all_prns_closed "$prns"; then
            echo "STALE: $pf_base (all PRNs closed: ${prns// /, })"
        fi
        # else CLEAN — emit nothing.
    done
    exit 0
fi

# ── Demote-check (advisory; never deletes/edits/blocks; always exit 0) ─────────
if $DEMOTE_CHECK; then
    # Collect committed PRN tokens and cited pending-*.md filenames since <ref>
    # (Auto-sync commits excluded: their body lists swept paths, see non_sweep_log).
    _committed=""
    if [[ -n "$DEMOTE_SINCE" && -d "$PROJECT_DIR/.git" ]]; then
        _committed=$(non_sweep_log "${DEMOTE_SINCE}..HEAD" | sed 's/^[SB] //')
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
        # Any real Tracked-by PRN committed since <ref>? A commit that MENTIONS
        # an ID is not the ID shipping (CFG-620): when the backlog has a line
        # for any tracked ID and that line is not "- [x]", the file still
        # tracks live work — no demote. With no backlog line to consult
        # (no backlog, another project's ID) the commit is the only signal.
        prns=$(get_tracked_prns "$pf")
        _open=""
        for prn in $prns; do
            case "$(prn_state "$prn")" in
                x|missing) ;;
                *) _open="$prn"; break ;;
            esac
        done
        [[ -n "$_open" ]] && continue
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
