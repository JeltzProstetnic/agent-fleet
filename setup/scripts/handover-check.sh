#!/usr/bin/env bash
# handover-check.sh — are all Recovery Instructions items carried into the handover?  CFG-204
# Usage: handover-check.sh [project-dir]     exit 0 = all carried, 1 = gap (listed on stderr)
#
# LRN audit 2026-03-16: the agent said "I'll add" an item to the handoff and didn't; the
# user caught it. rotate-session.sh copies `## Next Session Task` into next-session-task.md,
# but `## Recovery Instructions` only reaches session-history.md, which the next session
# reads on demand only — a promised item that never made it into the handover silently
# drops out of view. Also catches the two-commit shutdown (a first pass that rotated early).
#
# Handover = the `## Next Session Task` section + the file its `file:` line points at.
# Item    = a bullet or numbered line in `## Recovery Instructions` (prose is not an item;
#           HTML comments and placeholder bullets such as "—" or "none" are skipped).
# Carried = every task ID it names (PRJ-NN) appears in the handover, OR its text appears
#           there as written (case, markdown emphasis and whitespace ignored).
# Called by rotate-session.sh as a warning — rotation also runs in SessionEnd, so a gap
# must never block it.

set -uo pipefail

PROJECT_DIR="${1:-.}"
CTX="$PROJECT_DIR/session-context.md"
[ -f "$CTX" ] || exit 0

_strip_comments() {
    awk '{
        line = $0; out = ""
        while (1) {
            if (inc) { e = index(line, "-->"); if (!e) { line = ""; break }; line = substr(line, e + 3); inc = 0 }
            s = index(line, "<!--"); if (!s) { out = out line; break }
            out = out substr(line, 1, s - 1); line = substr(line, s + 4); inc = 1
        }
        print out
    }'
}

_section() {  # <heading>
    awk -v h="## $1" 'index($0, h) == 1 { f = 1; next } /^## / { f = 0 } f' "$CTX" | _strip_comments
}

_norm() {  # lowercase, drop markdown emphasis, collapse whitespace, trim a trailing period
    tr '[:upper:]' '[:lower:]' | tr -d '*`_~' | tr -s '[:space:]' ' ' \
        | sed -E 's/^ +//; s/ +$//; s/\.$//'
}

RECOVERY=$(_section "Recovery Instructions")
NEXT=$(_section "Next Session Task")

HANDOVER="$NEXT"
_target=$(printf '%s\n' "$NEXT" | sed -nE 's/^[[:space:]]*file:[[:space:]]*//p' | head -1 | tr -d '`"'"'" \
    | sed -E 's/[[:space:]]+$//')
if [ -n "$_target" ]; then
    case "$_target" in /*) ;; *) _target="$PROJECT_DIR/$_target" ;; esac
    [ -f "$_target" ] && HANDOVER="$HANDOVER
$(cat "$_target")"
fi
HANDOVER_NORM=$(printf '%s\n' "$HANDOVER" | _norm)

_missing=""
while IFS= read -r _line; do
    _item=$(printf '%s' "$_line" | sed -nE 's/^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]+//p')
    [ -n "$_item" ] || continue
    _n=$(printf '%s' "$_item" | _norm)
    case "$_n" in ''|'—'|'-'|none|n/a|tbd) continue ;; esac

    _ids=$(printf '%s' "$_item" | grep -oE '(^|[^A-Za-z0-9])[A-Z][A-Z0-9]{1,4}-[0-9]{2,}' \
        | sed -E 's/^[^A-Z]//' | sort -u)
    if [ -n "$_ids" ]; then
        _all=1
        for _id in $_ids; do
            printf '%s' "$HANDOVER" | grep -qwF "$_id" || { _all=0; break; }
        done
        [ "$_all" -eq 1 ] && continue
    fi
    case "$HANDOVER_NORM" in *"$_n"*) continue ;; esac
    _missing="${_missing}  - ${_item}
"
done <<EOF
$RECOVERY
EOF

[ -z "$_missing" ] && exit 0

{
    echo "HANDOVER GAP (CFG-204): these Recovery Instructions items are not carried into the handover"
    echo "(## Next Session Task${_target:+ + ${_target#"$PROJECT_DIR"/}}) — after rotation they survive only in"
    echo "session-history.md, which the next session does not read at startup:"
    printf '%s' "$_missing"
    echo "Copy each one into the handover file (by task ID or as written) before rotating."
} >&2
exit 1
