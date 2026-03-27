#!/usr/bin/env bash
# Check group 15b: Backlog health metrics (daily)
# Warns on: P0 items existing, >5 open P1 items.
# Shared vars used: PROJECT_DIR, WARNINGS

# Daily gate via sched-lib (if available) or fallback to inline marker
_sched_lib="${CONFIG_REPO:-}/setup/scripts/sched-lib.sh"
if [ -f "$_sched_lib" ]; then
    source "$_sched_lib"
    SCHED_MARKER_DIR="${SCHED_MARKER_DIR:-/tmp}"
    sched_is_due "backlog-health-check" "daily" || return 0 2>/dev/null || true
else
    # fallback inline marker
    _gate="/tmp/.backlog-health-check-$(date +%Y-%m-%d)"
    [ ! -f "$_gate" ] || return 0 2>/dev/null || true
    touch "$_gate"
fi

_backlog_file="$PROJECT_DIR/backlog.md"
[ -f "$_backlog_file" ] || return 0 2>/dev/null || true

_backlog_issues=""

# Count open P0 items (unchecked boxes with [P0])
_p0_count=$(grep -c '^\- \[ \] \[P0\]' "$_backlog_file" 2>/dev/null | head -1 || echo 0)
[ -z "$_p0_count" ] && _p0_count=0
if [ "$_p0_count" -gt 0 ]; then
    _backlog_issues="${_backlog_issues:+$_backlog_issues; }$_p0_count P0 item(s) in backlog"
fi

# Count open P1 items
_p1_count=$(grep -c '^\- \[ \] \[P1\]' "$_backlog_file" 2>/dev/null | head -1 || echo 0)
[ -z "$_p1_count" ] && _p1_count=0
if [ "$_p1_count" -gt 5 ]; then
    _backlog_issues="${_backlog_issues:+$_backlog_issues; }$_p1_count open P1 items (>5 — consider triage)"
fi

if [ -n "$_backlog_issues" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }BACKLOG_HEALTH: $_backlog_issues"
fi

# Mark done (sched-lib or fallback)
if type sched_mark_done &>/dev/null; then
    sched_mark_done "backlog-health-check" "daily"
elif [ -z "${_gate:-}" ]; then
    touch "/tmp/.backlog-health-check-$(date +%Y-%m-%d)"
fi
