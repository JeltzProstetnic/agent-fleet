#!/usr/bin/env bash
# PreToolUse hook (CFG-556): block pathspec-less `git add` when a shared,
# concurrently-written directory has pending changes.
#
# `git add -A|-u|.` stages every dirty file in the repo, including ones another
# running session is mid-edit. Three confirmed instances of a session sweeping
# another's in-progress cross-project/ triage into an unrelated commit. Nothing
# is lost, so nothing looks broken — which is why it kept recurring.
#
# This is a hook and not a rule on purpose: the third instance was committed by
# a session that had read the full write-up of the second one twenty minutes
# earlier. Startup knowledge does not survive to a mid-session git reflex.
#
# Deliberately NARROW — silent unless a real sweep is pending, and naming any
# pathspec explicitly always works. A guard that false-blocks trains the
# bypass (CFG-513), so it must never stand between the user and a legal commit.
#
# Exit 2 = block with message. Exit 0 = allow.

INPUT=$(cat)

# Bash tool only
if [[ "$INPUT" != *'"tool_name":"Bash"'* && "$INPUT" != *'"tool_name": "Bash"'* ]]; then
    exit 0
fi

CMD=""
if command -v jq &>/dev/null; then
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
    CMD=$(echo "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
          | sed 's/.*"command"[^"]*"\([^"]*\)"/\1/')
fi
[ -z "$CMD" ] && exit 0

# Cheap reject before any git work
[[ "$CMD" == *"git "*"add"* ]] || exit 0

# Shared directories to protect (space-separated, overridable)
SHARED_DIRS="${CC_SWEEP_GUARD_DIRS:-cross-project}"

# Walk each `git ... add ...` clause in a possibly-compound command.
# Splits on && || ; | and newlines, then inspects clauses that are a git add.
SWEEP=0
GIT_C_DIR=""
while IFS= read -r clause; do
    # shellcheck disable=SC2086
    set -- $clause
    [ "${1:-}" = "git" ] || continue

    shift
    local_c=""
    # consume pre-subcommand options (-C <dir>, -c k=v, --no-pager, ...)
    while [ $# -gt 0 ]; do
        case "$1" in
            -C) local_c="${2:-}"; shift 2 ;;
            -c) shift 2 ;;
            --no-pager|--no-replace-objects|--bare) shift ;;
            *) break ;;
        esac
    done
    [ "${1:-}" = "add" ] || continue
    shift

    has_flag=0 has_dotspec=0 has_explicit=0
    for tok in "$@"; do
        case "$tok" in
            -A|--all|-u|--update|-Au|-uA) has_flag=1 ;;
            .|:/|'*'|./|:/'*') has_dotspec=1 ;;
            -*) ;;                       # other flags: -n, -f, -v, --dry-run…
            *) has_explicit=1 ;;         # a real, named pathspec
        esac
    done

    # A named pathspec scopes the command — that is always the legal path.
    if [ "$has_explicit" -eq 1 ]; then continue; fi
    if [ "$has_flag" -eq 1 ] || [ "$has_dotspec" -eq 1 ]; then
        SWEEP=1; GIT_C_DIR="$local_c"; break
    fi
done < <(printf '%s\n' "$CMD" | tr '\n;|' '\n\n\n' | sed 's/&&/\n/g' | sed 's/^[[:space:]]*//')

[ "$SWEEP" -eq 1 ] || exit 0

# Resolve the repo the add would apply to
TARGET_DIR="${GIT_C_DIR:-$PWD}"
[ -d "$TARGET_DIR" ] || exit 0
ROOT=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$ROOT" ] || exit 0

# Which protected dirs actually exist here?
EXISTING=""
for d in $SHARED_DIRS; do
    [ -d "$ROOT/$d" ] && EXISTING="$EXISTING $d"
done
[ -n "$EXISTING" ] || exit 0

# shellcheck disable=SC2086
PENDING=$(git -C "$ROOT" status --porcelain --no-renames -- $EXISTING 2>/dev/null \
          | sed 's/^...//' | head -20)
[ -n "$PENDING" ] || exit 0

COUNT=$(printf '%s\n' "$PENDING" | grep -c .)
{
    echo "BLOCKED (CFG-556): this \`git add\` has no pathspec, and ${COUNT} file(s) under a shared directory are dirty:"
    printf '%s\n' "$PENDING" | sed 's/^/  /'
    echo ""
    echo "Another session may be mid-edit in there — a pathspec-less add commits its work under your message."
    echo "Stage what you actually touched by name instead, e.g.:  git add <path> [<path>...]"
    echo "If those files ARE yours, name them explicitly and this passes."
} >&2
exit 2
