#!/usr/bin/env bash
# dashboard-row.sh — Update ONE project's row in cross-project/dashboard-cache.md (CFG-576)
#
# Usage:
#   bash setup/scripts/dashboard-row.sh <project> [--tasks V] [--size V] | [--auto]
#                                                 [--deadline V] [--p1names V] [--lastdone V]
#
# Each flag REPLACES that cell (never appends). Cells without a flag are left as they are.
# --auto computes Tasks and Size from the row's own Path (backlog summary as lsd-refresh.sh,
#        `du -sh`; CFG-1093) — exit 1 when that path is not on this machine. Not with --tasks/--size.
# Env: DASHBOARD_CACHE (default: <this repo>/cross-project/dashboard-cache.md)
#      DASHBOARD_LOCK_TIMEOUT seconds to wait for the lock (default 10)
#      DASHBOARD_LOCK_STALE   age in seconds after which a lock is presumed dead (default 60)
#
# ⛔ Why this exists: sessions used to edit the cache by hand, and one wrote the whole file
#    from a buffer read before another session's commit landed — reverting that project's
#    freshly curated row to stale content. This script re-reads the file under a lock at
#    write time and rewrites only the caller's row, so a stale buffer is impossible and two
#    writers can never lose each other's update. Git merges row-scoped edits cleanly too.
#    lsd-refresh.sh takes the same lock (`<cache>.lock`, a directory) for its write phase.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${DASHBOARD_CACHE:-$(cd "$SCRIPT_DIR/../.." && pwd)/cross-project/dashboard-cache.md}"
LOCK="${CACHE}.lock"
LOCK_TIMEOUT="${DASHBOARD_LOCK_TIMEOUT:-10}"
LOCK_STALE="${DASHBOARD_LOCK_STALE:-60}"
NCOLS=10   # Project | Priority | Parent | Path | Type | Tasks | Size | Deadline | P1Names | LastDone

usage() {
    sed -n '4,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

[[ $# -ge 1 && "$1" != -* ]] || usage
PROJECT="$1"; shift

declare -A set_cell=()
AUTO=0
while [[ $# -gt 0 ]]; do
    if [[ "$1" == --auto ]]; then AUTO=1; shift; continue; fi
    [[ $# -ge 2 ]] || usage
    case "$1" in
        --tasks)    set_cell[5]="$2" ;;
        --size)     set_cell[6]="$2" ;;
        --deadline) set_cell[7]="$2" ;;
        --p1names)  set_cell[8]="$2" ;;
        --lastdone) set_cell[9]="$2" ;;
        *) usage ;;
    esac
    shift 2
done
if (( AUTO )); then
    [[ -z "${set_cell[5]+x}" && -z "${set_cell[6]+x}" ]] || usage
else
    (( ${#set_cell[@]} > 0 )) || usage
fi

if [[ ! -f "$CACHE" ]]; then
    echo "dashboard-row: cache not found: $CACHE (run lsd-refresh.sh once)" >&2
    exit 1
fi

# --auto: the slow part (du, backlog scan) happens here, BEFORE the lock, as in lsd-refresh.sh.
# The Path cell is registry-driven and does not change under a concurrent writer.
if (( AUTO )); then
    # shellcheck source=lib-dashboard.sh
    source "$SCRIPT_DIR/lib-dashboard.sh"
    # The row whose FIRST cell is the name — a substring match also hits a child row naming this
    # project as its Parent, and the live cache lists such a child first (Fable review 2026-11-27).
    _row=$(awk -F'|' -v p="$PROJECT" '{ n = $2; gsub(/^[ \t]+|[ \t]+$/, "", n) } n == p { print; exit }' "$CACHE")
    _path=""
    [[ -n "$_row" ]] && _path=$(dashboard_expand_path "$(awk -F'|' '{print $5}' <<<"$_row")")
    if [[ -z "$_row" ]]; then
        echo "dashboard-row: no row for project '$PROJECT' in $CACHE (add it to registry.md, then run lsd-refresh.sh)" >&2
        exit 3
    fi
    if [[ -z "$_path" || ! -d "$_path" ]]; then
        echo "dashboard-row: --auto: path '${_path:-?}' of '$PROJECT' is not on this machine — row unchanged" >&2
        exit 1
    fi
    set_cell[5]="—"
    [[ -f "$_path/backlog.md" ]] && set_cell[5]=$(summarise_backlog "$_path/backlog.md" | sed -n 1p)
    # Bounded: a cold `du` on a large tree must not push a shutdown past the Bash tool's 120 s.
    # Size is cosmetic and lsd-refresh.sh recomputes it, so a timeout writes a dash.
    _du=(du -sh "$_path")
    command -v timeout >/dev/null 2>&1 && _du=(timeout "${DASHBOARD_DU_TIMEOUT:-60}" "${_du[@]}")
    set_cell[6]=$("${_du[@]}" 2>/dev/null | awk '{print $1}' || true)
    [[ -n "${set_cell[6]}" ]] || set_cell[6]="—"
fi

# A cell can hold neither a newline nor a '|' — either one silently adds columns, and every
# reader (lsd, afleet's picker) splits on '|'. P1Names lists are joined with '; ' instead.
clean_value() {
    local v="$1"
    v="${v//$'\r'/}"
    v="${v//$'\n'/ }"
    v="${v//|/; }"
    v=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/;  */; /g' <<<"$v")
    printf '%s' "$v"
}

# Split a table row into exactly NCOLS cells (global array `cells`). Rows already damaged in
# the live file are repaired rather than trusted: a missing trailing cell is padded, and extra
# cells — pipe-joined P1Names — are folded back into P1Names, keeping the last as LastDone.
split_row() {
    local body="${1#|}"
    [[ "$body" == *'|' ]] && body="${body%|}"
    local -a raw=()
    IFS='|' read -r -a raw <<<"$body"
    local i v n=${#raw[@]}
    for ((i = 0; i < n; i++)); do
        v="${raw[i]}"
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        raw[i]="$v"
    done
    cells=()
    if (( n > NCOLS )); then
        cells=("${raw[@]:0:8}")
        local joined="" part
        for part in "${raw[@]:8:n-9}"; do
            [[ -z "$part" ]] && continue
            joined="${joined:+$joined; }$part"
        done
        cells+=("$joined" "${raw[n-1]}")
    else
        cells=("${raw[@]}")
        while (( ${#cells[@]} < NCOLS )); do cells+=(""); done
    fi
}

join_row() {
    local out="|" c
    for c in "${cells[@]}"; do out+=" $c |"; done
    printf '%s' "$out"
}

# GNU stat first, BSD/macOS second; a lock that vanished mid-check reads as "now".
mtime() {
    local t
    t=$(stat -c %Y "$1" 2>/dev/null) || t=$(stat -f %m "$1" 2>/dev/null) || t=""
    [[ "$t" =~ ^[0-9]+$ ]] || t=$(date +%s)
    printf '%s' "$t"
}

# mkdir is atomic on every filesystem and needs no flock (absent on macOS).
lock_acquire() {
    local tries=0 max=$(( LOCK_TIMEOUT * 10 ))
    until mkdir "$LOCK" 2>/dev/null; do
        if (( $(date +%s) - $(mtime "$LOCK") > LOCK_STALE )); then
            echo "dashboard-row: breaking stale lock $LOCK" >&2
            rmdir "$LOCK" 2>/dev/null || true
            continue
        fi
        if (( tries >= max )); then
            echo "dashboard-row: timed out after ${LOCK_TIMEOUT}s waiting for $LOCK" >&2
            return 1
        fi
        sleep 0.1
        tries=$((tries + 1))
    done
}

lock_acquire || exit 1
TMP=""
trap 'rm -f "$TMP"; rmdir "$LOCK" 2>/dev/null || true' EXIT

TMP=$(mktemp "${CACHE}.XXXXXX")
cp -p "$CACHE" "$TMP"   # carries the file mode across the atomic replace
found=0
{
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Cheap prefix test first; the exact-name comparison below is what decides.
        if [[ "$line" == "| $PROJECT "* ]]; then
            split_row "$line"
            if [[ "${cells[0]}" == "$PROJECT" ]]; then
                found=$((found + 1))
                for idx in "${!set_cell[@]}"; do
                    cells[idx]=$(clean_value "${set_cell[$idx]}")
                done
                line=$(join_row)
            fi
        fi
        printf '%s\n' "$line"
    done < "$CACHE"
} > "$TMP"

if (( found == 0 )); then
    echo "dashboard-row: no row for project '$PROJECT' in $CACHE (add it to registry.md, then run lsd-refresh.sh)" >&2
    exit 3
fi
mv -f "$TMP" "$CACHE"
TMP=""
echo "dashboard-row: updated $PROJECT"
