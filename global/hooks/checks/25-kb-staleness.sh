#!/usr/bin/env bash
# Check group 25: cross-project knowledge-base staleness (CFG-430).
# Checks: 25.1
# Shared vars used: PROJECT_DIR, CONFIG_REPO, WARNINGS, INBOX_MSG
#
# Startup git-sync-check syncs only the CURRENT project. A person lookup into a
# sibling KB repo (~/social, 25 days behind) silently returned "not found" for
# data that existed on origin. The behavioural rule ("fetch before reading any
# cross-project file") was rejected as a pre-step competing with the main
# action; this is the mechanical form: fetch the few KB-bearing repos listed
# in setup/config/kb-repos.conf and WARN when any is behind. 0 tokens.
#
# Bounded: KB_FETCH_TIMEOUT per fetch (4s, enforced with or without a
# `timeout` binary), KB_FETCH_BUDGET (8s) after which no new fetch starts — so
# the worst case is about budget + one fetch timeout — and no fetch at all
# when the repo's FETCH_HEAD is younger than
# KB_FETCH_MIN_AGE (600s) AND non-empty — a second session start minutes later
# costs nothing. A failed or killed fetch rewrites FETCH_HEAD too, EMPTY with a
# fresh mtime (git truncates it before contacting the remote), so an empty one
# is never taken as a recent fetch: that read "fresh" off a failure.
# Never fabricates "fresh" (CFG-611): a repo that could not be fetched is
# KB_UNCHECKED, never a 0-behind. The current project is step 0's job and is
# skipped; a repo not present on this machine or without an upstream is
# skipped silently.

# Check 25.1: KB-bearing sibling repos behind their upstream
_kb_conf="${KB_REPOS_CONF:-${CONFIG_REPO:-}/setup/config/kb-repos.conf}"
if [ -f "$_kb_conf" ]; then
    _kb_budget="${KB_FETCH_BUDGET:-8}"
    _kb_timeout="${KB_FETCH_TIMEOUT:-4}"
    _kb_min_age="${KB_FETCH_MIN_AGE:-600}"
    _kb_start=$(date +%s)
    _kb_self=$(git -C "${PROJECT_DIR:-.}" rev-parse --show-toplevel 2>/dev/null || echo "${PROJECT_DIR:-}")
    _kb_stale=""
    _kb_unchecked=""
    _kb_timeout_cmd=""
    command -v timeout >/dev/null 2>&1 && _kb_timeout_cmd="timeout $_kb_timeout"

    # One bounded fetch. With no `timeout` binary (stock macOS) the fetch runs
    # in the background and a watchdog kills it after KB_FETCH_TIMEOUT: an
    # unbounded fetch could outlast Claude Code's hook timeout, and a killed
    # hook drops the WHOLE SessionStart payload. Every fd of the fetch and the
    # watchdog points at /dev/null so nothing left running can hold the
    # hook's stdout open.
    _kb_fetch() {
        if [ -n "$_kb_timeout_cmd" ]; then
            GIT_TERMINAL_PROMPT=0 $_kb_timeout_cmd git -C "$1" fetch --quiet </dev/null >/dev/null 2>&1
            return
        fi
        GIT_TERMINAL_PROMPT=0 git -C "$1" fetch --quiet </dev/null >/dev/null 2>&1 &
        local _pid=$! _dog _rc
        ( sleep "$_kb_timeout"; kill "$_pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        _dog=$!
        wait "$_pid" 2>/dev/null; _rc=$?
        kill "$_dog" 2>/dev/null; wait "$_dog" 2>/dev/null
        return "$_rc"
    }

    while IFS= read -r _kb_line || [ -n "$_kb_line" ]; do
        _kb_line="${_kb_line%%#*}"
        _kb_line="${_kb_line#"${_kb_line%%[![:space:]]*}"}"
        _kb_line="${_kb_line%"${_kb_line##*[![:space:]]}"}"
        [ -n "$_kb_line" ] || continue
        _kb_path="${_kb_line/#\~/$HOME}"
        [ -d "$_kb_path" ] || continue
        _kb_top=$(git -C "$_kb_path" rev-parse --show-toplevel 2>/dev/null) || continue
        [ "$_kb_top" != "$_kb_self" ] || continue
        git -C "$_kb_path" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 || continue
        _kb_name=$(basename "$_kb_top")

        # Fetch unless recently fetched; stop fetching once the budget is spent.
        _kb_fetched=1
        _kb_fh=$(git -C "$_kb_path" rev-parse --git-path FETCH_HEAD 2>/dev/null)
        case "$_kb_fh" in /*) ;; *) _kb_fh="$_kb_path/$_kb_fh" ;; esac
        _kb_fh_age="$_kb_min_age"
        if [ -s "$_kb_fh" ]; then
            _kb_fh_mtime=$(stat -c %Y "$_kb_fh" 2>/dev/null || stat -f %m "$_kb_fh" 2>/dev/null || echo 0)
            _kb_fh_age=$(( $(date +%s) - _kb_fh_mtime ))
        fi
        if [ "$_kb_fh_age" -lt "$_kb_min_age" ]; then
            :   # fetched within the window — compare against what is already here
        elif [ $(( $(date +%s) - _kb_start )) -ge "$_kb_budget" ]; then
            _kb_fetched=0
        elif ! _kb_fetch "$_kb_path"; then
            _kb_unchecked="${_kb_unchecked:+$_kb_unchecked, }$_kb_name (fetch failed)"
            continue
        fi

        if [ "$_kb_fetched" -eq 0 ]; then
            _kb_unchecked="${_kb_unchecked:+$_kb_unchecked, }$_kb_name (not fetched — ${_kb_budget}s budget spent)"
            continue
        fi
        _kb_behind=$(git -C "$_kb_path" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
        if [ "${_kb_behind:-0}" -gt 0 ] 2>/dev/null; then
            _kb_stale="${_kb_stale:+$_kb_stale, }$_kb_name ($_kb_behind behind)"
        fi
    done < "$_kb_conf"

    if [ -n "$_kb_stale" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }KB_STALE: sibling knowledge repos behind origin — $_kb_stale — 'git -C ~/<repo> pull --ff-only' before any cross-project lookup, or data that exists on origin reads as 'not found'."
    fi
    if [ -n "$_kb_unchecked" ]; then
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }KB_UNCHECKED: $_kb_unchecked — freshness unknown, treat as possibly stale."
    fi
    unset _kb_conf _kb_budget _kb_timeout _kb_min_age _kb_start _kb_self _kb_stale _kb_unchecked \
          _kb_timeout_cmd _kb_line _kb_path _kb_top _kb_name _kb_fetched _kb_fh _kb_fh_age _kb_fh_mtime _kb_behind
    unset -f _kb_fetch
fi
