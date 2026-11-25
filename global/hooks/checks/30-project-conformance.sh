#!/usr/bin/env bash
# Check group 30: project conformance — this project carries what a new project receives (CFG-1094).
#
# Runs setup/scripts/project-conformance.sh --project on THIS project: the mechanical items
# (template .githooks/pre-commit, project-gitignore.conf lines, a retired-name pointer in the
# manifest — the only CLAUDE.md text it rewrites, Q-1094-INBOX) are fixed in the tree, the rest
# (marker, type knowledge rows the global CLAUDE.md does not already trigger, tracked tmp/
# files) becomes ONE idempotent P2 backlog item (check-10 precedent; a project's own
# .githooks/pre-commit is only noted; a `.fleet-conformance-skip` in the project root opts the
# whole project out), and ONE line tells the session what was fixed and that it
# must commit it (Q-1094-COMMIT). The hook never commits. Silent when nothing is to do, in
# directories that are not registered projects, in $HOME, the mobile snapshot and nested dirs.
# No network, no registry sweep (that is check 31, cfg sessions only). ALL logic lives in the
# script; a missing or crashed script is reported, never swallowed.
# On a branch behind its fetched upstream the script writes nothing and says "deferred" (INBOX):
# the startup pull (git-sync-check.sh --pull, step 0) would otherwise abort on the untracked
# .githooks/pre-commit it also brings (MAJOR 1); the next start finds what is really left.
# Shared vars used: PROJECT_DIR, CONFIG_REPO, WARNINGS, INBOX_MSG

_pc_dir="${PROJECT_DIR:-}"
_pc_root=$(cd "$_pc_dir" 2>/dev/null && pwd -P)
# Only a project repo's own root: never $HOME (the global CLAUDE.md lives there), never the
# read-only mobile repo, never a directory inside another repo.
if [ -n "$_pc_root" ] && [ "$_pc_root" != "$(cd "$HOME" 2>/dev/null && pwd -P)" ] && [ ! -f "$_pc_dir/.mobile-repo" ] \
   && [ "$(git -C "$_pc_dir" rev-parse --show-toplevel 2>/dev/null)" = "$_pc_root" ]; then
    _pc_script="${CONFIG_REPO:-}/setup/scripts/project-conformance.sh"
    if [ ! -f "$_pc_script" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }PROJECT_CONFORMANCE: script missing at $_pc_script — this project's conformance is unchecked."
    else
        # The script always prints one line — "ok" or "not a registered project" when there is
        # nothing to say — so a crash, a timeout or an empty run is reported, never swallowed.
        _pc_out=""; _pc_rc=0
        _pc_out=$(timeout "${PROJECT_CONFORMANCE_TIMEOUT:-20}" bash "$_pc_script" --project "$_pc_dir" --fix --file-backlog --brief 2>/dev/null) || _pc_rc=$?
        _pc_line=$(printf '%s' "$_pc_out" | tr '\n' ' ' | sed 's/ *$//')
        if [ "$_pc_rc" -eq 124 ]; then
            WARNINGS="${WARNINGS:+$WARNINGS | }PROJECT_CONFORMANCE: script timed out after ${PROJECT_CONFORMANCE_TIMEOUT:-20}s — this project's conformance is unchecked."
        elif [ "$_pc_rc" -ne 0 ]; then
            WARNINGS="${WARNINGS:+$WARNINGS | }PROJECT_CONFORMANCE: script failed (rc $_pc_rc) — this project's conformance is unchecked.${_pc_line:+ Output: $_pc_line}"
        else
            case "$_pc_line" in
                "") WARNINGS="${WARNINGS:+$WARNINGS | }PROJECT_CONFORMANCE: script produced no output — this project's conformance is unchecked." ;;
                "PROJECT_CONFORMANCE: ok"|"PROJECT_CONFORMANCE: not a registered project") ;;   # nothing to say
                "PROJECT_CONFORMANCE: opted out ("*) ;;   # .fleet-conformance-skip in the project root (Q-1094-SEARXNG)
                PROJECT_CONFORMANCE:\ deferred*) INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }$_pc_line" ;;
                PROJECT_CONFORMANCE*) WARNINGS="${WARNINGS:+$WARNINGS | }$_pc_line" ;;
                *) WARNINGS="${WARNINGS:+$WARNINGS | }PROJECT_CONFORMANCE: unrecognized output — $_pc_line" ;;
            esac
        fi
    fi
fi
