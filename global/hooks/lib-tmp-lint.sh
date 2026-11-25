#!/usr/bin/env bash
# lib-tmp-lint.sh — the one definition of "tmp/ is a leak risk here" (CFG-490, CFG-1094).
# Sourced by checks/25-tmp-lint.sh (every session, cfg sweeps the registry) and by
# setup/scripts/project-conformance-lib.sh (the conformance check files the tracked-files
# half as a backlog item). Read-only: never edits a repo.

[[ "${_LIB_TMP_LINT_LOADED:-}" == "true" ]] && return 0
_LIB_TMP_LINT_LOADED="true"

# tmp_lint_issue <dir> → "N tracked file(s) under tmp/" | "tmp/ is not gitignored" | "" (clean,
# or not a repo root — a project nested in another repo is that repo's business).
tmp_lint_issue() {
    local d="$1" n
    [ "$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" = "$d" ] || return 0
    n=$(tmp_lint_tracked_count "$d")
    if [ "${n:-0}" -gt 0 ]; then
        printf '%s tracked file(s) under tmp/' "$n"
    elif ! git -C "$d" check-ignore -q tmp/.tmp-lint-probe 2>/dev/null; then
        printf 'tmp/ is not gitignored'
    fi
}

# tmp_lint_tracked_count <dir> → the number of tracked files under tmp/, placeholders excluded.
# A tracked placeholder (tmp/.gitkeep, a self-ignoring tmp/.gitignore) is deliberate (CFG-658).
tmp_lint_tracked_count() {
    git -C "$1" ls-files -- tmp 2>/dev/null | grep -cvxE 'tmp/\.(gitkeep|keep|gitignore)' || true
}
