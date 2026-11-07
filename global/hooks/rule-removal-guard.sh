#!/usr/bin/env bash
# PreToolUse hook (CFG-897): no approved rule disappears silently.
#
# A 2026-10-30 audit of this fleet's rule files ("find out what else you merged into oblivion")
# found rules gone with no recorded owner decision: "User actions go LAST" and CFG-609 "never a
# bare ordinal" dropped by 0a26da91, "Feature self-integrity" by 61765dd3, the subagent
# file-creation guardrail by 3d8cb52c (an Auto-sync commit nobody reviewed), "Parallelization
# is mandatory" moved out of the always-loaded CLAUDE.md by 1e6c6741. Root cause: replacements
# were written fresh and executed as "replace bullet"; Meta-Rules step 1 checks the NEW text,
# nothing checked that each removed sentence was moved, merged or retired by the owner. This
# guard refuses a `git commit` that drops a sentence or table row from a rule file unless the
# commit's own message carries a verified trailer for it (key matched case-insensitively):
#   Rule-removed: "<text>" moved-to <path>          text present in the STAGED version of <path>
#   Rule-removed: "<text>" merged-into "<title>"    a heading or **bold label** (≥ 8 chars) of a staged rule file
#   Rule-removed: "<text>" retired-by <who> <date>  any approver token, a real date, not in the future
# Rule files: every CLAUDE.md, and *.md directly under foundation/, reference/ or knowledge/
# below global/ or .claude/. A move to another file IS a removal here — moving a rule out of
# CLAUDE.md into a conditionally loaded file is exactly how rules got weakened — and a rule
# file renamed out of rule scope is a deletion.
# Sees what the commit will record: the index, plus the working tree for -a, a pathspec, or a
# `git add`/`rm`/`mv` earlier in the same call (lib-commit-scan.sh). Other same-call writes
# (`sed -i`, `>`) before a plain commit are not modelled: the index is what is judged. --amend
# is judged against HEAD^ and, with no -m/-F, keeps HEAD's message; a merge or rebase in
# progress passes through; non-commit commands and other tools pass.
# Message: -m/--message/--trailer values, -F <file>, the heredoc or here-string feeding -F -,
# a $(cat <<'EOF' …) value. A message the guard cannot read ($VAR, -c <commit>) blocks when
# removals exist. Detector and thresholds: lib-rule-removal.sh. Without python3 the guard
# cannot judge and passes (documented limitation).
#
# Also a CLI for the SessionEnd hook and for audits (no hook JSON on stdin):
#   rule-removal-guard.sh --check-staged <repo>    exit 1 + offending paths on stdout
#   rule-removal-guard.sh --replay <commit> [repo] would this recorded commit have been blocked?
# Exit 2 = block. Exit 0 = allow.

_RRG_DIR="$(dirname "${BASH_SOURCE[0]}")"
_rrg_libs() {
    local d
    for d in "$_RRG_DIR" "${HOME:-}/.claude/hooks" "${CONFIG_REPO:-}/global/hooks"; do
        [ -f "$d/lib-commit-scan.sh" ] && [ -f "$d/lib-rule-removal.sh" ] || continue
        # shellcheck source=lib-commit-scan.sh
        source "$d/lib-commit-scan.sh" && source "$d/lib-rule-removal.sh" && return 0
    done
    return 1
}

case "${1:-}" in
    --check-staged|--replay)
        command -v python3 >/dev/null 2>&1 || { echo "rule-removal-guard: python3 missing — cannot judge" >&2; exit 0; }
        _rrg_libs || { echo "rule-removal-guard: lib-commit-scan.sh / lib-rule-removal.sh not found beside $_RRG_DIR" >&2; exit 0; }
        python3 -c "$_RULE_REMOVAL_PY" "$@"
        exit $? ;;
esac

INPUT=$(cat)
case "$INPUT" in
    *'"tool_name":"Bash"'*|*'"tool_name": "Bash"'*) ;;
    *) exit 0 ;;
esac
CMD=""
if command -v jq >/dev/null 2>&1; then
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
fi
if [ -z "$CMD" ]; then
    CMD=$(printf '%s' "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
          | sed 's/.*"command"[^"]*"\([^"]*\)"/\1/')
fi
[ -z "$CMD" ] && exit 0

# Cheap reject before any git or python work.
case "$CMD" in
    *git*commit*) ;;
    *) exit 0 ;;
esac
command -v python3 >/dev/null 2>&1 || exit 0
_rrg_libs || exit 0

# The lexer's records go through a file: they are NUL-separated and a bash variable cannot
# hold NUL. ${TMPDIR:-/tmp} — the CC sandbox mounts /tmp read-only and points TMPDIR elsewhere.
_tmp=$(mktemp "${TMPDIR:-/tmp}/rrg-jobs.XXXXXX" 2>/dev/null) || _tmp=$(mktemp /tmp/rrg-jobs.XXXXXX 2>/dev/null) || exit 0
printf '%s' "$CMD" | python3 -c "$_COMMIT_SCAN_PY" --with-messages > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; exit 0; }
_report=$(python3 -c "$_RULE_REMOVAL_PY" --jobs "$_tmp" 2>&1); _rc=$?
rm -f "$_tmp"
case "$_rc" in
    0) exit 0 ;;
    1) printf '%s\n' "$_report" >&2; exit 2 ;;
    *) echo "rule-removal-guard: detector failed (exit $_rc) — not blocking: ${_report:0:200}"; exit 0 ;;
esac
