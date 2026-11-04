#!/usr/bin/env bash
# install-git-hooks.sh — arm the fleet git hook dispatcher on this machine (CFG-892)
#
# Usage: install-git-hooks.sh [--check]
#
# Sets `git config --global core.hooksPath "$HOME/.claude/hooks/git"` so that EVERY push
# from this machine runs the pre-push credential scan (global/hooks/git/pre-push),
# whoever made the commits — scripts, the SessionEnd auto-sync, MG's own shell — none of
# which secret-commit-guard.sh sees. The dispatcher chains each repo's own .githooks/*
# and .git/hooks/* so nothing a repo already had goes dead.
#
# sync.sh deploy calls this after deploy_hooks on every machine. It must never fail the
# deploy, so every install outcome exits 0:
#   unset                    → set it, report "armed"
#   already the dispatcher   → silent (idempotent; runs on every session end)
#   anything else            → leave it, ONE warning. A global hooksPath somebody set on
#                              purpose is not ours to redirect; the owner decides.
#   dispatcher not deployed  → do not arm. Pointing hooksPath at a missing dir would
#                              silently disable every repo's .git/hooks. Warn.
#   --check                  → report the state, change nothing; exit 0 armed, 1 otherwise
#
# Last resort, owner only: `FLEET_PREPUSH_SCAN=0 git push …` skips the scan LOUDLY (the hook
# prints a warning naming CFG-892) and still chains the repo's own hooks. Never in a script.

set -uo pipefail

DISPATCHER="$HOME/.claude/hooks/git"
MODE="${1:-install}"

case "$MODE" in
    install|--check) ;;
    *) echo "Usage: install-git-hooks.sh [--check]" >&2; exit 2 ;;
esac

current="$(git config --global --get core.hooksPath 2>/dev/null || true)"

if [[ "$MODE" == "--check" ]]; then
    echo "install-git-hooks (CFG-892): global core.hooksPath = ${current:-<unset>}"
    if [[ -x "$DISPATCHER/pre-push" ]]; then
        echo "  dispatcher: $DISPATCHER/pre-push present"
    else
        echo "  dispatcher: $DISPATCHER/pre-push MISSING (run sync.sh deploy)"
    fi
    echo "  escape (owner only, last resort, never in a script): FLEET_PREPUSH_SCAN=0 git push …"
    if [[ "$current" == "$DISPATCHER" && -x "$DISPATCHER/pre-push" ]]; then
        echo "  state: armed — every push from this machine is scanned for credentials"
        exit 0
    fi
    echo "  state: not armed — pushes from this machine are NOT scanned"
    exit 1
fi

# A REPO-LOCAL core.hooksPath overrides the global one, so the scan never runs in that
# repo. Measured 2026-11-04 on the reference workstation: three repos carried
# <repo>/.git/hooks (no real hooks in it, set by something outside this repo) and five
# carried .githooks — the scan would have run in none of them.
# Once OUR dispatcher is the global value, a local value it already chains (.githooks or
# .git/hooks, relative or absolute) is removed; any other local value is reported, never
# removed. Sweeps every repo one or two levels under $HOME (project groups), every deploy.
_sweep_local_shadows() {
    local d v
    for d in "$HOME"/*/ "$HOME"/*/*/; do
        d="${d%/}"
        [[ -e "$d/.git" ]] || continue
        v="$(git -C "$d" config --local --get core.hooksPath 2>/dev/null)" || continue
        case "$v" in
            .githooks|.githooks/|.git/hooks|.git/hooks/|"$d/.githooks"|"$d/.githooks/"|"$d/.git/hooks"|"$d/.git/hooks/")
                git -C "$d" config --local --unset core.hooksPath \
                    && echo "install-git-hooks (CFG-892): $d — removed local core.hooksPath '$v' (it shadowed the dispatcher, which chains it)" ;;
            *)
                echo "install-git-hooks (CFG-892): $d has a custom local core.hooksPath '$v' — it shadows the fleet pre-push scan; left as is" >&2 ;;
        esac
    done
    return 0
}

if [[ ! -x "$DISPATCHER/pre-push" ]]; then
    echo "install-git-hooks (CFG-892): $DISPATCHER/pre-push is not deployed — not arming core.hooksPath (run sync.sh deploy first)" >&2
    exit 0
fi

[[ "$current" == "$DISPATCHER" ]] && { _sweep_local_shadows; exit 0; }

if [[ -n "$current" ]]; then
    echo "install-git-hooks (CFG-892): global core.hooksPath is already '$current' — left as is; the fleet pre-push credential scan is NOT armed on this machine (unset it, or point it at $DISPATCHER)" >&2
    exit 0
fi

if ! git config --global core.hooksPath "$DISPATCHER"; then
    echo "install-git-hooks (CFG-892): could not write the global git config — the pre-push scan is not armed" >&2
    exit 0
fi
echo "install-git-hooks (CFG-892): armed — global core.hooksPath = $DISPATCHER (every push from this machine is now scanned)"
_sweep_local_shadows
