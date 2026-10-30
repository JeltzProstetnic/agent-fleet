#!/usr/bin/env bash
# GPI — Grind Progress Indicator
# CLI for managing statusline progress state
#
# Usage:
#   gpi.sh start  <id> <label> [--group <g>] [--seq <n/m>] [--eta <secs>] [--log <path>] [--tmux <session>]
#   gpi.sh update <id> [--pct <0-100>] [--detail <str>] [--eta <secs>]
#   gpi.sh done   <id>
#   gpi.sh clear  [--dead | --group <g> | --all]
#   gpi.sh status
#
# State file: GPI_STATE env var or ~/.claude/.gpi-state.json
# GPI_IDLE_REAP_SECS: `clear --dead` reaps an op that has no tmux_session once nothing has
#   updated it for this long (default 21600 = 6 h; CFG-875).
#
# CFG-863: the state file is MACHINE-global while sessions are per project, so nothing
# here may drop an op it cannot prove finished. Every write replaces the file atomically,
# only a non-empty jq result is ever written, and a blank or invalid file is repaired.

set -euo pipefail

STATE_FILE="${GPI_STATE:-$HOME/.claude/.gpi-state.json}"
LOCK_FILE="${STATE_FILE}.lock"
COMPLETED_FILE="${GPI_COMPLETED:-$HOME/.claude/.gpi-completed.json}"

# Atomic replace (CFG-863 D): tmp in the same directory + rename, so a concurrent reader
# sees the old file or the new one, never a truncated one. Refuses empty content.
atomic_write() {
    local path="$1" content="$2" tmp
    [[ -n "$content" ]] || return 1
    tmp=$(mktemp "${path}.XXXXXX") || return 1
    if printf '%s\n' "$content" > "$tmp"; then
        mv -f "$tmp" "$path"
    else
        rm -f "$tmp"
        return 1
    fi
}

# Ensure the state file exists AND is usable (CFG-863 C). The old check recreated only a
# MISSING file: a blank or invalid one (left by a failed write) stayed broken for good —
# jq on empty input succeeds with no output, so every later command silently did nothing.
ensure_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    (
        flock 9
        jq -e 'type == "object" and (.ops | type == "object")' "$STATE_FILE" >/dev/null 2>&1 \
            || atomic_write "$STATE_FILE" '{"ops":{},"updated":0}'
    ) 9>"$LOCK_FILE"
}

# Locked read-modify-write. Extra arguments go to jq (--arg/--argjson). Writes only a
# non-empty jq SUCCESS (CFG-863 C): `tmp=$(jq …); echo "$tmp" >` blanked the file whenever
# jq failed — and `set -e` is off inside a `cleanup_x || true` caller, so it did not stop.
locked_update() {
    local jq_expr="$1"
    shift
    ensure_state
    (
        flock 9
        local tmp
        tmp=$(jq "$@" "$jq_expr" "$STATE_FILE") && [[ -n "$tmp" ]] && atomic_write "$STATE_FILE" "$tmp"
    ) 9>"$LOCK_FILE"
}

# Remove completed ops older than 60 seconds
cleanup_completed() {
    local now
    now=$(date +%s)
    locked_update '.ops = (.ops | to_entries | map(select(
            (.value.completed_at // null) == null or ($now - .value.completed_at) <= 60
        )) | from_entries)' --argjson now "$now"
}

# Remove orphaned ops older than 24 hours (no completed_at, stale started)
# Safety net for entries that survive crashes or missed SessionEnd hooks.
# `started // $now`: an op without it counts as fresh instead of failing the whole sweep.
cleanup_stale() {
    local now
    now=$(date +%s)
    locked_update '.ops = (.ops | to_entries | map(select(
            (.value.completed_at // null) != null or ($now - (.value.started // $now)) <= 86400
        )) | from_entries)' --argjson now "$now"
}

# Write notification sidecar for session awareness (atomic, self-healing on a bad file)
write_notification() {
    local id="$1" label="$2" now existing tmp
    now=$(date +%s)
    mkdir -p "$(dirname "$COMPLETED_FILE")"
    existing=$(jq -c 'if type == "array" then . else [] end' "$COMPLETED_FILE" 2>/dev/null || true)
    [[ -n "$existing" ]] || existing='[]'
    tmp=$(jq -n --argjson old "$existing" --arg id "$id" --arg label "$label" --argjson ts "$now" \
        '$old + [{"id": $id, "label": $label, "completed_at": $ts}]') && atomic_write "$COMPLETED_FILE" "$tmp"
}

cmd_start() {
    local id="$1" label="$2"
    shift 2
    local group="null" seq_index="null" seq_total="null" eta="null" log_path="null" tmux_session="null"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --group) group="\"$2\""; shift 2 ;;
            --seq)
                seq_index="${2%%/*}"
                seq_total="${2##*/}"
                shift 2 ;;
            --eta) eta="$2"; shift 2 ;;
            --log) log_path="\"$2\""; shift 2 ;;
            # CFG-863: the job's tmux session, so `clear --dead` and the statusline can tell a
            # killed job from a quiet one. tmux-launch.sh passes it; an op without it is
            # never judged dead.
            --tmux) tmux_session="\"$2\""; shift 2 ;;
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
            log_path: $log_path,
            tmux_session: $tmux_session,
            updated_at: $now
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
    # Per-op last-update stamp: the idle reap in `clear --dead` reads it (CFG-875).
    jq_parts+=(".ops[\"$id\"].updated_at = $now")
    jq_parts+=(".updated = $now")

    local expr
    expr=$(IFS='|'; echo "${jq_parts[*]}" | sed 's/|/ | /g')
    locked_update "$expr"
}

cmd_done() {
    local id="$1"
    ensure_state
    # An op already expired or cleared must not come back as a label-less "[? DONE]" stub.
    [[ -n "$(jq -r ".ops[\"$id\"] // empty" "$STATE_FILE")" ]] || return 0
    # Get label for notification
    local label
    label=$(jq -r ".ops[\"$id\"].label // \"$id\"" "$STATE_FILE")
    local now
    now=$(date +%s)
    # Mark as completed (auto-cleanup will remove it after 60s)
    locked_update ".ops[\"$id\"].completed_at = $now | .updated = $now"
    # Write notification sidecar for session awareness. The op is done once it is marked:
    # a failed sidecar write must not turn that into exit 1 (CFG-875).
    write_notification "$id" "$label" 2>/dev/null || true
    return 0
}

# Ids of unfinished ops whose RECORDED tmux session no longer exists (CFG-863). "No server"
# means every recorded session is gone; any other tmux failure proves nothing, so nothing
# is dead. Exact name match — plain `tmux -t <name>` prefix-matches (CFG-616 family).
# 10 s grace after `started`: tmux-launch.sh registers the op BEFORE it creates the
# session, so a brand-new op has no session yet and must not be reaped for that.
dead_tmux_ids() {
    local out rc=0 id sess now
    command -v tmux >/dev/null 2>&1 || return 0
    out=$(tmux list-sessions -F '#{session_name}' 2>&1) || rc=$?
    if (( rc != 0 )); then
        grep -qE 'no server running|No such file or directory' <<<"$out" || return 0
        out=""
    fi
    now=$(date +%s)
    jq -r --argjson now "$now" '.ops | to_entries[]
        | select((.value.completed_at // null) == null and (.value.tmux_session // null) != null
                 and ($now - (.value.started // $now)) > 10)
        | "\(.key)\t\(.value.tmux_session)"' "$STATE_FILE" 2>/dev/null |
    while IFS=$'\t' read -r id sess; do
        grep -qxF -- "$sess" <<<"$out" || printf '%s\n' "$id"
    done
}

cmd_clear() {
    local group="" all=false dead=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --group) group="$2"; shift 2 ;;
            --all) all=true; shift ;;
            --dead) dead=true; shift ;;
            *) echo "gpi clear: unknown argument '$1' (use: clear | clear --dead | clear --all | clear --group <g>; finish one op with: done <id>)" >&2
               return 2 ;;
        esac
    done

    local now
    now=$(date +%s)

    if [[ -n "$group" ]]; then
        locked_update '.ops = (.ops | to_entries | map(select(.value.group != $g)) | from_entries) | .updated = $now' \
            --arg g "$group" --argjson now "$now"
    elif [[ "$all" == true ]]; then
        locked_update '.ops = {} | .updated = $now' --argjson now "$now"
    elif [[ "$dead" == true ]]; then
        # CFG-863: what SessionEnd runs — completed ops plus ops whose recorded tmux session
        # is gone. Never a running op: the file is shared by every project on the machine.
        # CFG-875: an op WITHOUT a tmux_session can never be judged by tmux, so it is reaped
        # once nothing has updated it for GPI_IDLE_REAP_SECS (default 6 h). Shorter than
        # cleanup_stale's 24 h since start, which already runs on every call — a 24 h idle
        # rule here would never fire. updated_at // started covers ops written before the stamp.
        local dead_ids
        dead_ids=$(dead_tmux_ids | jq -R . | jq -s .)
        locked_update '.ops = (.ops | to_entries | map(select(
                (.value.completed_at // null) == null and ((.key as $k | $dead | index($k)) == null)
                and (((.value.tmux_session // null) != null)
                     or ($now - (.value.updated_at // .value.started // $now)) <= $idle)
            )) | from_entries) | .updated = $now' --argjson dead "${dead_ids:-[]}" --argjson now "$now" \
            --argjson idle "${GPI_IDLE_REAP_SECS:-21600}"
    else
        # Default: remove only completed entries (those with completed_at set)
        locked_update '.ops = (.ops | to_entries | map(select((.value.completed_at // null) == null)) | from_entries) | .updated = $now' \
            --argjson now "$now"
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

# Auto-cleanup on every invocation
cleanup_completed 2>/dev/null || true
cleanup_stale 2>/dev/null || true

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
