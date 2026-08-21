#!/usr/bin/env bash
# ensure-githooks.sh — arm a repo's tracked .githooks/ directory (CFG-535)
#
# Usage: ensure-githooks.sh [repo-dir ...]     (defaults to the cfg repo's siblings)
#
# WHY THIS EXISTS. `~/agent-fleet` is a PUBLIC repository, and the SessionEnd hook
# (`config-auto-sync.sh`) commits and pushes to it automatically. That push path runs
# NO leak check of its own — the leak gate lives in `template-push.sh`, which this
# path never calls. The only thing between a session's private notes and publication
# is the repo's own `.githooks/pre-push` guard.
#
# Nothing installed that guard. `grep -c hooksPath sync.sh` returned 0. Git does not
# honour a tracked hooks directory unless `core.hooksPath` points at it, and that
# setting lives in `.git/config`, which is untracked and therefore per-clone. On this
# workstation it happened to be set by hand; on a fresh clone anywhere else the files
# are present, the guard is inert, and the push succeeds.
#
# Measured 2026-08-21: two auto-sync commits carrying the workstation hostname and
# absolute home paths sat in the public clone, unpublished only because of that one
# accidental line. Publication is irreversible, so this is armed everywhere, every
# session, rather than documented as a setup step someone must remember.
#
# Deliberately conservative: it only ever arms a repo that ACTUALLY ships
# `.githooks/pre-push`, and it never overwrites a hooksPath somebody set on purpose.

set -uo pipefail

_ensure_one() {
    local repo="$1"
    [[ -d "$repo/.git" ]] || return 0                 # not a git repo — nothing to do
    [[ -f "$repo/.githooks/pre-push" ]] || return 0    # ships no guard — leave alone

    local current
    current="$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)"

    # Already armed — stay silent so this can run on every session end.
    [[ "$current" == ".githooks" ]] && return 0

    # Somebody pointed this somewhere deliberate. Not ours to redirect; say so once.
    if [[ -n "$current" && "$current" != ".git/hooks" && "$current" != "$repo/.git/hooks" ]]; then
        echo "ensure-githooks: $repo has a custom core.hooksPath ($current) — left as is" >&2
        return 0
    fi

    git -C "$repo" config core.hooksPath .githooks || return 1
    echo "ensure-githooks: armed pre-push guard in $repo"
}

main() {
    local rc=0
    if [[ $# -gt 0 ]]; then
        local d
        for d in "$@"; do _ensure_one "$d" || rc=1; done
    else
        # Default sweep: every sibling fleet repo that ships a guard.
        local d
        for d in "$HOME"/*agent-fleet*; do
            [[ -d "$d" ]] && { _ensure_one "$d" || rc=1; }
        done
    fi
    return $rc
}

main "$@"
