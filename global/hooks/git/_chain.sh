#!/usr/bin/env bash
# _chain.sh — run the repo-level hooks that a global core.hooksPath shadows (CFG-892).
#
# Usage: _chain.sh <hook-name> [hook args…]      stdin: the hook's stdin, forwarded
#
# Git runs exactly ONE hooks directory. With core.hooksPath pointing at this fleet
# dispatcher dir, a repo's tracked .githooks/<name> (agent-fleet's leak scrubber, the
# project template's commit-size guard) and its .git/hooks/<name> (git-lfs installs
# four) would be silently dead. Every hook file in this dir therefore ends by running
# this chain, in order:
#   1. <toplevel>/.githooks/<name>      (tracked, per repo)
#   2. <git-common-dir>/hooks/<name>    (untracked, per clone — the COMMON dir, so a
#                                        linked worktree or a submodule finds its own)
# Same args, same stdin (buffered once), and the first non-zero exit is returned with
# the rest skipped — what git does with a single failing hook. Git runs hooks from the
# worktree root (or $GIT_DIR in a bare repo); nothing here changes directory, so a
# relative GIT_DIR or a message-file argument still resolves for the chained hook.
#
# No scanning happens here. Not a hook name itself (the leading underscore keeps git
# from ever invoking it), and the pass-through stubs just chain, errors and all.

set -u
name="${1:?hook name}"; shift

# Buffer stdin once, bytes intact (the trailing-newline-preserving form).
input="$(cat; printf x)"; input="${input%x}"

_abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
[ -n "$common" ] && common="$(_abs "$common")"
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

for h in "${top:+$top/.githooks/$name}" "${common:+$common/hooks/$name}"; do
    [ -n "$h" ] && [ -f "$h" ] || continue
    # Never re-enter this dispatcher (a hooks dir symlinked at it would loop forever).
    [ "$(cd "$(dirname "$h")" 2>/dev/null && pwd -P)" = "$self" ] && continue
    if [ ! -x "$h" ]; then
        echo "hint: $h was ignored because it is not executable (fleet dispatcher, CFG-892)" >&2
        continue
    fi
    # Git falls back to sh for a hook without a shebang; mirror that.
    if [ "$(head -c 2 "$h" 2>/dev/null)" = "#!" ]; then
        printf '%s' "$input" | "$h" "$@"
    else
        printf '%s' "$input" | sh "$h" "$@"
    fi
    rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
done
exit 0
