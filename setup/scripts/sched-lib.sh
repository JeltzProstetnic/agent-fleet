#!/usr/bin/env bash
# sched-lib.sh — Scheduled task library for agent-fleet
# Provides: task registration, date-gating, scope matching, resolution, execution
# Sourced by check 19 (global/hooks/checks/19-scheduled-tasks.sh)

# ── State ─────────────────────────────────────────────────────────────────────

# Parallel arrays for registered tasks (bash 3.2+ compatible — no associative arrays)
_SCHED_IDS=()
_SCHED_INTERVALS=()
_SCHED_SCOPES=()
_SCHED_EXECS=()
_SCHED_DESCS=()
_SCHED_CMDS=()
_SCHED_MACHINES=()
_SCHED_PROJECTS=()

# Overridable config
SCHED_MARKER_DIR="${SCHED_MARKER_DIR:-/tmp}"
SCHED_MACHINE="${SCHED_MACHINE:-}"
SCHED_PROJECT="${SCHED_PROJECT:-}"

# Valid values
_SCHED_VALID_INTERVALS="every-session daily weekly monthly"
_SCHED_VALID_SCOPES="fleet per-machine per-project per-machine-project"
_SCHED_VALID_EXECS="auto prompted manual"

# ── Registration ──────────────────────────────────────────────────────────────

sched_reset() {
    _SCHED_IDS=()
    _SCHED_INTERVALS=()
    _SCHED_SCOPES=()
    _SCHED_EXECS=()
    _SCHED_DESCS=()
    _SCHED_CMDS=()
    _SCHED_MACHINES=()
    _SCHED_PROJECTS=()
}

sched_count() {
    echo "${#_SCHED_IDS[@]}"
}

sched_task() {
    local id="$1"; shift
    local interval="" scope="" exec_type="" desc="" cmd="" machine="" project=""

    # Parse named arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval) interval="$2"; shift 2 ;;
            --scope)    scope="$2"; shift 2 ;;
            --exec)     exec_type="$2"; shift 2 ;;
            --desc)     desc="$2"; shift 2 ;;
            --cmd)      cmd="$2"; shift 2 ;;
            --machine)  machine="$2"; shift 2 ;;
            --project)  project="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Validate
    if [[ -z "$id" ]]; then
        echo "sched_task: empty task ID" >&2
        return 1
    fi

    # Check for duplicate
    local i
    for i in "${!_SCHED_IDS[@]}"; do
        if [[ "${_SCHED_IDS[$i]}" == "$id" ]]; then
            echo "sched_task: duplicate ID '$id'" >&2
            return 1
        fi
    done

    if ! _sched_valid "$interval" "$_SCHED_VALID_INTERVALS"; then
        echo "sched_task: invalid interval '$interval' (valid: $_SCHED_VALID_INTERVALS)" >&2
        return 1
    fi
    if ! _sched_valid "$scope" "$_SCHED_VALID_SCOPES"; then
        echo "sched_task: invalid scope '$scope' (valid: $_SCHED_VALID_SCOPES)" >&2
        return 1
    fi
    if ! _sched_valid "$exec_type" "$_SCHED_VALID_EXECS"; then
        echo "sched_task: invalid exec '$exec_type' (valid: $_SCHED_VALID_EXECS)" >&2
        return 1
    fi

    # Register
    _SCHED_IDS+=("$id")
    _SCHED_INTERVALS+=("$interval")
    _SCHED_SCOPES+=("$scope")
    _SCHED_EXECS+=("$exec_type")
    _SCHED_DESCS+=("$desc")
    _SCHED_CMDS+=("$cmd")
    _SCHED_MACHINES+=("$machine")
    _SCHED_PROJECTS+=("$project")
}

_sched_valid() {
    local val="$1" valid="$2"
    local v
    for v in $valid; do
        [[ "$val" == "$v" ]] && return 0
    done
    return 1
}

# ── Date Gating ───────────────────────────────────────────────────────────────

_sched_date_key() {
    local interval="$1"
    case "$interval" in
        every-session) echo "session" ;;
        daily)         date +%Y-%m-%d ;;
        weekly)        date +%Y-W%V ;;
        monthly)       date +%Y-%m ;;
    esac
}

_sched_marker_path() {
    local id="$1" interval="$2"
    local key
    key=$(_sched_date_key "$interval")
    echo "${SCHED_MARKER_DIR}/.sched-${id}-${key}"
}

sched_is_due() {
    local id="$1" interval="$2"
    [[ "$interval" == "every-session" ]] && return 0
    local marker
    marker=$(_sched_marker_path "$id" "$interval")
    [[ ! -f "$marker" ]]
}

sched_mark_done() {
    local id="$1" interval="$2"
    [[ "$interval" == "every-session" ]] && return 0
    local marker
    marker=$(_sched_marker_path "$id" "$interval")
    touch "$marker"
}

# ── Scope Matching ────────────────────────────────────────────────────────────

sched_matches_scope() {
    local scope="$1" task_machine="$2" task_project="$3"
    case "$scope" in
        fleet) return 0 ;;
        per-machine)
            [[ -n "$task_machine" && "$SCHED_MACHINE" == "$task_machine" ]]
            ;;
        per-project)
            [[ -n "$task_project" && "$SCHED_PROJECT" == "$task_project" ]]
            ;;
        per-machine-project)
            [[ "$SCHED_MACHINE" == "$task_machine" && "$SCHED_PROJECT" == "$task_project" ]]
            ;;
        *) return 1 ;;
    esac
}

# ── Resolution ────────────────────────────────────────────────────────────────

sched_resolve() {
    local filter_exec="${1:-}"
    local i
    for i in "${!_SCHED_IDS[@]}"; do
        local id="${_SCHED_IDS[$i]}"
        local interval="${_SCHED_INTERVALS[$i]}"
        local scope="${_SCHED_SCOPES[$i]}"
        local exec_type="${_SCHED_EXECS[$i]}"
        local machine="${_SCHED_MACHINES[$i]}"
        local project="${_SCHED_PROJECTS[$i]}"

        # Filter by exec type if specified
        if [[ -n "$filter_exec" && "$exec_type" != "$filter_exec" ]]; then
            continue
        fi

        # Check scope
        if ! sched_matches_scope "$scope" "$machine" "$project"; then
            continue
        fi

        # Check if due
        if ! sched_is_due "$id" "$interval"; then
            continue
        fi

        echo "$id"
    done
}

# ── Execution ─────────────────────────────────────────────────────────────────

sched_run_auto() {
    local due
    due=$(sched_resolve "auto")
    [[ -z "$due" ]] && return 0

    local id
    while IFS= read -r id; do
        local i
        for i in "${!_SCHED_IDS[@]}"; do
            if [[ "${_SCHED_IDS[$i]}" == "$id" ]]; then
                local cmd="${_SCHED_CMDS[$i]}"
                local interval="${_SCHED_INTERVALS[$i]}"
                if [[ -n "$cmd" ]]; then
                    eval "$cmd" 2>&1 || true
                fi
                sched_mark_done "$id" "$interval"
                break
            fi
        done
    done <<< "$due"
}

sched_get_warnings() {
    local due
    due=$(sched_resolve "prompted")
    [[ -z "$due" ]] && return 0

    local id
    while IFS= read -r id; do
        local i
        for i in "${!_SCHED_IDS[@]}"; do
            if [[ "${_SCHED_IDS[$i]}" == "$id" ]]; then
                echo "[PROMPTED] ${id}: ${_SCHED_DESCS[$i]}"
                break
            fi
        done
    done <<< "$due"
}

sched_get_reminders() {
    local due
    due=$(sched_resolve "manual")
    [[ -z "$due" ]] && return 0

    local id
    while IFS= read -r id; do
        local i
        for i in "${!_SCHED_IDS[@]}"; do
            if [[ "${_SCHED_IDS[$i]}" == "$id" ]]; then
                echo "[REMINDER] ${id}: ${_SCHED_DESCS[$i]}"
                break
            fi
        done
    done <<< "$due"
}
