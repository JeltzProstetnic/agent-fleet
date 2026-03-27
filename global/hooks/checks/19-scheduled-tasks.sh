#!/usr/bin/env bash
# Check 19: Scheduled task system
# Resolves due tasks for this machine+project, executes auto tasks,
# surfaces prompted/manual tasks via WARNINGS/INBOX_MSG.
# Depends on: sched-lib.sh, setup/config/scheduled-tasks.sh

# Find config repo
_sched_config_repo="${CONFIG_REPO:-}"
if [[ -z "$_sched_config_repo" ]]; then
    # Fallback: detect from script location
    _sched_config_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../" && pwd)"
fi

# Source library
_sched_lib="$_sched_config_repo/setup/scripts/sched-lib.sh"
[[ -f "$_sched_lib" ]] || return 0 2>/dev/null || exit 0
source "$_sched_lib"

# Detect machine from HOSTNAME (matches CLAUDE.md identity table)
_sched_detect_machine() {
    local hn="${HOSTNAME:-$(hostname 2>/dev/null)}"
    local user="${USER:-$(whoami 2>/dev/null)}"
    case "$hn" in
        srv943133)       echo "vps" ;;
        DESKTOP-*)       echo "wsl" ;;
        steamdeck*|jupiter*) echo "steamdeck" ;;
        nuc*)            echo "nuc" ;;
        fedora*)
            [[ "$user" == "gruber" ]] && echo "office" || echo "fedora-home"
            ;;
        *)               echo "" ;;
    esac
}

# Detect project from PWD
_sched_detect_project() {
    local dir="${PROJECT_DIR:-$PWD}"
    basename "$dir"
}

SCHED_MACHINE="$(_sched_detect_machine)"
SCHED_PROJECT="$(_sched_detect_project)"

# Load fleet-wide tasks
_fleet_tasks="$_sched_config_repo/setup/config/scheduled-tasks.sh"
[[ -f "$_fleet_tasks" ]] && source "$_fleet_tasks"

# Load machine overlay tasks
if [[ -n "$SCHED_MACHINE" ]]; then
    _machine_tasks="$_sched_config_repo/setup/config/machines/$SCHED_MACHINE/tasks.sh"
    [[ -f "$_machine_tasks" ]] && source "$_machine_tasks"
fi

# Resolve and execute auto tasks (silent, no confirmation)
_auto_output=$(sched_run_auto 2>&1) || true
if [[ -n "$_auto_output" ]]; then
    # Auto task output goes to INBOX_MSG for agent consumption
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG; }SCHED_AUTO: $_auto_output"
fi

# Collect prompted task warnings
_prompted=$(sched_get_warnings 2>/dev/null) || true
if [[ -n "$_prompted" ]]; then
    WARNINGS="${WARNINGS:+$WARNINGS; }$_prompted"
fi

# Collect manual reminders
_reminders=$(sched_get_reminders 2>/dev/null) || true
if [[ -n "$_reminders" ]]; then
    WARNINGS="${WARNINGS:+$WARNINGS; }$_reminders"
fi
