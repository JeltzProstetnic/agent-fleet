#!/usr/bin/env bash
# Check group 31: project drift — do the registered projects carry what a new one receives? (CFG-1094)
#
# Surfaces the PROJECT_DRIFT line produced by setup/scripts/project-conformance.sh --if-due:
# a date-gated (daily, sched-lib) READ-ONLY sweep of every project in registry.md that is
# checked out on this machine, nested and dormant ones included; absent projects are named,
# never skipped. The fixes happen in each project's own SessionStart (check 30) or in the
# one-time backfill (--sweep --fix --commit-push, run by hand). On gated sessions this is a
# pure cache read. ALL logic lives in the script — none here. Pattern of 22-fleet-drift.sh.
#
# Contract: exactly one PROJECT_DRIFT line per cfg session. OK → INBOX_MSG, [WARN] → WARNINGS.
# Silence never occurs — a missing script, a crash or an empty probe is reported.
# Shared vars used: PROJECT_DIR, CONFIG_REPO, WARNINGS, INBOX_MSG

_pd_project_dir="${PROJECT_DIR:-}"
_pd_config_repo="${CONFIG_REPO:-}"

# Only the config repo's own sessions sweep the registry — every other project pays nothing.
[ -n "$_pd_project_dir" ] && [ "$_pd_project_dir" = "$_pd_config_repo" ] \
    || return 0 2>/dev/null || true

_pd_script="$_pd_config_repo/setup/scripts/project-conformance.sh"
if [ ! -f "$_pd_script" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }PROJECT_DRIFT: probe script missing at $_pd_script — project conformance across the fleet is unmonitored."
    return 0 2>/dev/null || true
fi

# Bounded: ~40 projects × a handful of git calls; a hung probe degrades to a warning.
_pd_line=""
_pd_line=$(timeout "${PROJECT_DRIFT_CHECK_TIMEOUT:-60}" bash "$_pd_script" --if-due 2>/dev/null \
    | tr '\n' ' ' | sed 's/ *$//') || _pd_line=""

if [ -z "$_pd_line" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }PROJECT_DRIFT: probe produced no output (crashed or timed out) — project conformance is unmonitored until 'bash $_pd_script --force' reports."
    return 0 2>/dev/null || true
fi

case "$_pd_line" in
    PROJECT_DRIFT\[*) WARNINGS="${WARNINGS:+$WARNINGS | }$_pd_line" ;;
    PROJECT_DRIFT:*)  INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }$_pd_line" ;;
    *) WARNINGS="${WARNINGS:+$WARNINGS | }PROJECT_DRIFT: probe produced unrecognized output — $_pd_line" ;;
esac
