#!/usr/bin/env bash
# Check group 22: fleet drift — head-vantage visibility over registered installations (CFG-615).
#
# Surfaces the FLEET_DRIFT line produced by setup/scripts/fleet-drift.sh, which
# probes the installations registered in setup/config/fleet-installations.conf
# (mirrors, deployments) from a local vantage repo. The probe is date-gated
# (daily, sched-lib) inside the script; on gated sessions this is a pure cache
# read. ALL git/network logic lives in the script — none here. Supersedes the
# severity-blind symmetric counting that check 08 cannot provide for sub-fleets.
#
# Contract: exactly one FLEET_DRIFT line per cfg session. OK → INBOX_MSG,
# NOTE/WARN/SEVERE → WARNINGS. Silence never occurs — a crashed, hung or empty
# probe is reported as a degradation, never swallowed, so a missing line is
# itself a detectable fault.
# Shared vars used: PROJECT_DIR, CONFIG_REPO, WARNINGS, INBOX_MSG

_FD_PROJECT_DIR="${PROJECT_DIR:-}"
_FD_CONFIG_REPO="${CONFIG_REPO:-}"

# Only the config repo's own sessions own fleet visibility — every other
# project returns immediately and pays nothing.
[ -n "$_FD_PROJECT_DIR" ] && [ "$_FD_PROJECT_DIR" = "$_FD_CONFIG_REPO" ] \
    || return 0 2>/dev/null || true

_fd_script="$_FD_CONFIG_REPO/setup/scripts/fleet-drift.sh"
if [ ! -f "$_fd_script" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }FLEET_DRIFT: probe script missing at $_fd_script — sub-fleet drift is unmonitored."
    return 0 2>/dev/null || true
fi

# Bounded as a whole: the script bounds each remote probe individually (8s),
# this outer bound catches everything else. A hung probe degrades to a warning;
# it never blocks startup.
_fd_line=""
_fd_line=$(timeout "${FLEET_DRIFT_CHECK_TIMEOUT:-60}" bash "$_fd_script" --if-due 2>/dev/null \
    | tr '\n' ' ' | sed 's/ *$//') || _fd_line=""

if [ -z "$_fd_line" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }FLEET_DRIFT: probe produced no output (crashed or timed out) — sub-fleet drift is unmonitored until 'bash $_fd_script --force' reports."
    return 0 2>/dev/null || true
fi

case "$_fd_line" in
    FLEET_DRIFT\[*)
        WARNINGS="${WARNINGS:+$WARNINGS | }$_fd_line"
        ;;
    FLEET_DRIFT:*)
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }$_fd_line"
        ;;
    *)
        WARNINGS="${WARNINGS:+$WARNINGS | }FLEET_DRIFT: probe produced unrecognized output — $_fd_line"
        ;;
esac
