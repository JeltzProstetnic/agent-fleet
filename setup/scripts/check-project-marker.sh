#!/usr/bin/env bash
# check-project-marker.sh — assert the agent-fleet-managed marker is LINE 1 of a project's
# CLAUDE.md (CFG-484 / CFG-571)
#
# Usage:
#   check-project-marker.sh <project-dir>...
#   check-project-marker.sh --registry [<registry.md>]   # every registered project present here
#
# Output: one line per failing project — "MISSING <dir>: <reason>". Exit 0 when every checked
# project passes, 1 when any fails, 2 on usage error. Read-only: it never edits a CLAUDE.md.
#
# Why: a CLAUDE.md written outside the type templates (a project split, a hand-made project)
# has shipped without the marker three separate times, and every session
# in such a project then gets a false "may have been overwritten by /init" warning
# (checks/12-init-guard.sh). The templates carry the marker on line 1; this is the check a
# split or a new-project setup runs to prove the result does too. The marker anywhere else in
# the file satisfies the /init guard's grep but not the contract, so position is asserted.
set -uo pipefail

MARKER_RE='agent-fleet-managed'

usage() { sed -n '5,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# check_one <dir> — prints a MISSING line and returns 1 on failure.
check_one() {
    local dir="${1%/}" f="" line
    for f in "$dir/CLAUDE.md" "$dir/.claude/CLAUDE.md"; do
        [[ -f "$f" ]] && break
        f=""
    done
    if [[ -z "$f" ]]; then
        echo "MISSING $dir: no CLAUDE.md (looked in ./ and .claude/)"
        return 1
    fi
    head -1 "$f" | grep -q "$MARKER_RE" && return 0
    line=$(grep -n -m1 "$MARKER_RE" "$f" | cut -d: -f1)
    if [[ -n "$line" ]]; then
        echo "MISSING $dir: marker is on line $line of $f, must be line 1"
    else
        echo "MISSING $dir: $f has no agent-fleet-managed marker (line 1 must be the template's marker comment)"
    fi
    return 1
}

# Project paths from the registry's "## Projects" table only (Path = 4th column; the first
# backticked token wins, ~ expands). Other tables — machines, roster snapshots — are ignored.
registry_paths() {
    awk -F'|' -v home="$HOME" '
        /^## / { in_projects = ($0 ~ /^## Projects/); next }
        !in_projects || !/^\| / { next }
        {
            name = $2; p = $5
            gsub(/^[ \t]+|[ \t]+$/, "", name)
            if (name == "Project" || name ~ /^-+$/) next
            if (match(p, /`[^`]+`/)) p = substr(p, RSTART + 1, RLENGTH - 2)
            gsub(/^[ \t]+|[ \t]+$/, "", p)
            sub(/^~/, home, p)
            if (p ~ /^\//) print p   # only real paths; archive rows carry repo names or prose
        }' "$1"
}

[[ $# -ge 1 ]] || usage
dirs=()
if [[ "$1" == "--registry" ]]; then
    reg="${2:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)/registry.md}"
    [[ -f "$reg" ]] || { echo "check-project-marker: registry not found: $reg" >&2; exit 2; }
    while IFS= read -r p; do
        [[ -d "$p" ]] && dirs+=("$p")   # a project not on this machine is skipped, not failed
    done < <(registry_paths "$reg")
else
    for a in "$@"; do
        [[ "$a" == -* ]] && usage
        dirs+=("$a")
    done
fi

rc=0
for d in "${dirs[@]}"; do
    check_one "$d" || rc=1
done
exit "$rc"
