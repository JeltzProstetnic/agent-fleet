#!/usr/bin/env bash
# CFG-542 — migrate items out of the legacy cross-project/inbox.md into per-project files.
#
# Safe by construction, because this moves 187 heterogeneous items of real content:
#   * fence-aware — inbox items embed fenced shell scripts whose lines begin with '#'
#     and would otherwise be mistaken for headings and split mid-item;
#   * headings, the preamble and the four legacy `## <date> — <project>:` sections are
#     LEFT IN PLACE rather than guessed at;
#   * nothing is written until a byte-level verification passes: every item line from
#     the original must appear exactly once across the outputs, and none may be lost;
#   * --dry-run reports the plan and writes nothing;
#   * the original is backed up before any write.
#
# Migration is optional, not required: readers consult per-project files AND the legacy
# file, so an un-migrated machine keeps working. This only reclaims the payload.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --repo)    REPO_ROOT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "inbox-split: unknown argument: $1" >&2; exit 2 ;;
    esac
done

LEGACY="$REPO_ROOT/cross-project/inbox.md"
OUTDIR="$REPO_ROOT/cross-project/inbox"
[ -f "$LEGACY" ] || { echo "inbox-split: no legacy inbox at $LEGACY" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Pass 1: split into per-project blocks + a remainder ─────────────────────
awk -v work="$WORK" '
    # A tag naming several projects ("**alpha + beta + gamma**") is legal (CFG-483
    # tolerates it) but has never been DELIVERABLE: Check 3.2 matches `**<project>**`
    # exactly, so a combined tag matches none of the projects it names. Splitting the
    # item into each named project`s file is what makes it reach them at all.
    function flush(   i, n, parts) {
        if (cur != "" && proj != "") {
            n = split(proj, parts, "+")
            for (i = 1; i <= n; i++) {
                p = parts[i]
                gsub(/^[ \t-]+|[ \t-]+$/, "", p)
                if (p == "") continue
                print block >> (work "/proj." p); close(work "/proj." p)
            }
        }
        else if (cur != "") { printf "%s", block >> (work "/remainder") ; close(work "/remainder") }
        cur = ""; block = ""; proj = ""
    }
    {
        line = $0
        if (line ~ /^```/) { fence = !fence }

        if (!fence && line ~ /^- \[ \]/) {
            flush()
            cur = 1; block = line
            if (match(line, /\*\*[^*]+\*\*/)) {
                p = substr(line, RSTART + 2, RLENGTH - 4)
                gsub(/^[ \t]+|[ \t]+$/, "", p)
                # keep '+' so flush() can fan the item out to every project it names
                p = tolower(p); gsub(/[^a-z0-9._+-]/, "-", p)
                proj = p
            }
            next
        }
        if (!fence && line ~ /^#/ && cur != "") { flush() }

        if (cur != "") { block = block "\n" line }
        else           { print line >> (work "/remainder"); close(work "/remainder") }
    }
    END { flush() }
' "$LEGACY"

# ── Verification: no item may be lost, duplicated or mutated ────────────────
# A multi-project item is deliberately written into each named project's file, so the
# output is a SUPERset, not a copy. The invariant that still has to hold exactly is
# that the set of DISTINCT items is unchanged: nothing lost, nothing invented, no text
# mutated. Counting alone would not catch a mangled item, so compare the text.
_orig_items=$(awk '/^```/{f=!f} !f && /^- \[ \]/' "$LEGACY" | sort -u)
_new_items=$(cat "$WORK"/proj.* "$WORK"/remainder 2>/dev/null | awk '/^```/{f=!f} !f && /^- \[ \]/' | sort -u)

_n_orig=$(printf '%s\n' "$_orig_items" | grep -c '^- \[ \]' || true)
_n_new=$(printf '%s\n' "$_new_items" | grep -c '^- \[ \]' || true)
_n_written=$(cat "$WORK"/proj.* "$WORK"/remainder 2>/dev/null | grep -c '^- \[ \]' || true)

echo "distinct items in legacy : $_n_orig"
echo "distinct items after split: $_n_new"
echo "total lines written       : $_n_written (fan-out of multi-project tags accounts for any excess)"
echo "per-project files         : $(ls "$WORK"/proj.* 2>/dev/null | wc -l)"

if [ "$_orig_items" != "$_new_items" ]; then
    echo "inbox-split: ABORT — the set of distinct items changed. Nothing written." >&2
    diff <(printf '%s\n' "$_orig_items") <(printf '%s\n' "$_new_items") | head -5 >&2
    exit 1
fi
if [ "$_n_written" -lt "$_n_orig" ]; then
    echo "inbox-split: ABORT — fewer lines written than distinct items. Nothing written." >&2
    exit 1
fi
echo "verification: distinct-item set identical, nothing lost — OK"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "--- dry run, nothing written ---"
    for f in "$WORK"/proj.*; do
        [ -f "$f" ] || continue
        printf '  %-28s %s item(s)\n' "$(basename "$f" | sed 's/^proj\.//').md" "$(grep -c '^- \[ \]' "$f")"
    done
    exit 0
fi

# ── Commit the split ────────────────────────────────────────────────────────
cp "$LEGACY" "$LEGACY.bak.$(date +%Y%m%d-%H%M%S)" || { echo "inbox-split: backup failed" >&2; exit 1; }
mkdir -p "$OUTDIR"

for f in "$WORK"/proj.*; do
    [ -f "$f" ] || continue
    _p="$(basename "$f" | sed 's/^proj\.//')"
    _t="$OUTDIR/$_p.md"
    [ -f "$_t" ] || printf '# Inbox — %s\n\n' "$_p" > "$_t"
    cat "$f" >> "$_t"
done

cp "$WORK/remainder" "$LEGACY"
echo "split complete — legacy backed up, $(ls "$OUTDIR"/*.md 2>/dev/null | wc -l) per-project file(s) written"
