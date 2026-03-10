#!/usr/bin/env bash
# GPI — Grind Progress Indicator
# CLI for managing statusline progress state
#
# Usage:
#   gpi.sh start  <id> <label> [--group <g>] [--seq <n/m>] [--eta <secs>]
#   gpi.sh update <id> [--pct <0-100>] [--detail <str>] [--eta <secs>]
#   gpi.sh done   <id>
#   gpi.sh clear  [--group <g>]
#   gpi.sh status
#
# State file: GPI_STATE env var or ~/.claude/.gpi-state.json

set -euo pipefail

STATE_FILE="${GPI_STATE:-$HOME/.claude/.gpi-state.json}"
LOCK_FILE="${STATE_FILE}.lock"

# Ensure state file exists with empty ops
ensure_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        mkdir -p "$(dirname "$STATE_FILE")"
        echo '{"ops":{},"updated":0}' > "$STATE_FILE"
    fi
}

# Atomic read-modify-write with flock
locked_update() {
    local jq_expr="$1"
    ensure_state
    (
        flock 9
        local tmp
        tmp=$(jq "$jq_expr" "$STATE_FILE")
        echo "$tmp" > "$STATE_FILE"
    ) 9>"$LOCK_FILE"
}

cmd_start() {
    local id="$1" label="$2"
    shift 2
    local group="null" seq_index="null" seq_total="null" eta="null" log_path="null"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --group) group="\"$2\""; shift 2 ;;
            --seq)
                seq_index="${2%%/*}"
                seq_total="${2##*/}"
                shift 2 ;;
            --eta) eta="$2"; shift 2 ;;
            --log) log_path="\"$2\""; shift 2 ;;
            *) shift ;;
        esac
    done

    local now
    now=$(date +%s)

    locked_update "
        .ops[\"$id\"] = {
            label: \"$label\",
            pct: null,
            detail: null,
            group: $group,
            started: $now,
            eta_secs: $eta,
            seq_index: $seq_index,
            seq_total: $seq_total,
            log_path: $log_path
        }
        | .updated = $now
    "
}

cmd_update() {
    local id="$1"
    shift

    ensure_state
    # Check op exists
    local exists
    exists=$(jq -r ".ops[\"$id\"] // empty" "$STATE_FILE")
    if [[ -z "$exists" ]]; then
        echo "gpi: unknown operation '$id'" >&2
        return 1
    fi

    local jq_parts=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pct) jq_parts+=(".ops[\"$id\"].pct = $2"); shift 2 ;;
            --detail) jq_parts+=(".ops[\"$id\"].detail = \"$2\""); shift 2 ;;
            --eta) jq_parts+=(".ops[\"$id\"].eta_secs = $2"); shift 2 ;;
            *) shift ;;
        esac
    done

    local now
    now=$(date +%s)
    jq_parts+=(".updated = $now")

    local expr
    expr=$(IFS='|'; echo "${jq_parts[*]}" | sed 's/|/ | /g')
    locked_update "$expr"
}

cmd_done() {
    local id="$1"
    local now
    now=$(date +%s)
    locked_update "del(.ops[\"$id\"]) | .updated = $now"
}

cmd_clear() {
    local group=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --group) group="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local now
    now=$(date +%s)

    if [[ -n "$group" ]]; then
        locked_update ".ops = (.ops | to_entries | map(select(.value.group != \"$group\")) | from_entries) | .updated = $now"
    else
        locked_update ".ops = {} | .updated = $now"
    fi
}

cmd_status() {
    ensure_state
    local count
    count=$(jq '.ops | length' "$STATE_FILE")
    if [[ "$count" -eq 0 ]]; then
        echo "No active operations."
        return
    fi
    echo "Active operations ($count):"
    jq -r '.ops | to_entries[] | "  \(.key): \(.value.label) \(if .value.pct then "\(.value.pct)%" else "..." end)\(if .value.seq_index then " [\(.value.seq_index)/\(.value.seq_total)]" else "" end)\(if .value.group then " group=\(.value.group)" else "" end)\(if .value.detail then " \(.value.detail)" else "" end)"' "$STATE_FILE"
}

# ── Main dispatch ────────────────────────────────────────────────────────────

case "${1:-}" in
    start)  shift; cmd_start "$@" ;;
    update) shift; cmd_update "$@" ;;
    done)   shift; cmd_done "$@" ;;
    clear)  shift; cmd_clear "$@" ;;
    status) cmd_status ;;
    *)
        echo "Usage: gpi.sh {start|update|done|clear|status} [args]" >&2
        exit 1
        ;;
esac
