#!/usr/bin/env bash
# Check group 13: File LOC scaling thresholds (daily)
# Surfaces warnings when files exceed size limits, suggesting refactoring or splitting.
# Shared vars used: CONFIG_REPO, WARNINGS

# Daily gate via sched-lib (if available) or fallback to inline marker
_sched_lib="${CONFIG_REPO:-}/setup/scripts/sched-lib.sh"
if [ -f "$_sched_lib" ]; then
    source "$_sched_lib"
    SCHED_MARKER_DIR="${SCHED_MARKER_DIR:-/tmp}"
    sched_is_due "scaling-check" "daily" || return 0 2>/dev/null || true
else
    # fallback inline marker
    _gate="/tmp/.scaling-check-$(date +%Y-%m-%d)"
    [ ! -f "$_gate" ] || return 0 2>/dev/null || true
    touch "$_gate"
fi

_scaling_violations=""
_scaling_count=0

# _check_files <glob_pattern> <soft_limit> <hard_limit> <category_label>
_check_files() {
    local pattern="$1" soft="$2" hard="$3" label="$4"
    local f lines fname
    # Use eval to expand the glob against CONFIG_REPO
    for f in $(eval echo "$pattern"); do
        [ -f "$f" ] || continue
        lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
        [ "$lines" -le "$soft" ] 2>/dev/null && continue
        fname="${f#"$CONFIG_REPO"/}"
        if [ "$lines" -gt "$hard" ]; then
            _scaling_violations="${_scaling_violations:+$_scaling_violations; }${fname} (${lines}L) HARD LIMIT — must split ($label, hard=$hard)"
        else
            _scaling_violations="${_scaling_violations:+$_scaling_violations; }${fname} (${lines}L) soft limit ($label, warn=$soft)"
        fi
        _scaling_count=$((_scaling_count + 1))
    done
}

# Bash scripts: setup/scripts/*.sh, sync.sh
_check_files "$CONFIG_REPO/setup/scripts/*.sh" 400 600 "bash"
_check_files "$CONFIG_REPO/sync.sh" 400 600 "bash"

# Test files: setup/tests/*.sh
_check_files "$CONFIG_REPO/setup/tests/*.sh" 800 1500 "test"

# Knowledge/reference .md
_check_files "$CONFIG_REPO/global/knowledge/*.md" 200 350 "knowledge/ref"
_check_files "$CONFIG_REPO/global/reference/*.md" 200 350 "knowledge/ref"

# Hook check modules: global/hooks/checks/*.sh
_check_files "$CONFIG_REPO/global/hooks/checks/*.sh" 100 150 "hook-check"

# Hook scripts (non-checks): global/hooks/*.sh
_check_files "$CONFIG_REPO/global/hooks/*.sh" 200 300 "hook"

if [ "$_scaling_count" -gt 0 ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }SCALING: $_scaling_count file(s) exceed LOC thresholds: $_scaling_violations"
fi

# Mark done (sched-lib or fallback)
if type sched_mark_done &>/dev/null; then
    sched_mark_done "scaling-check" "daily"
elif [ -z "${_gate:-}" ]; then
    touch "/tmp/.scaling-check-$(date +%Y-%m-%d)"
fi
