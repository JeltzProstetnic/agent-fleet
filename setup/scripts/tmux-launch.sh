#!/usr/bin/env bash
# tmux-launch.sh — Launch a tmux session with automatic GPI registration.
# Replaces raw `tmux new-session -d` for long-running ops.
#
# Usage: tmux-launch.sh <session-name> "<gpi-label>" "<command>"
#        tmux-launch.sh <session-name> "<gpi-label>" --log <path> "<command>"
#
# Example:
#   tmux-launch.sh chaos-scan "Scanning _chaos" --log /tmp/scan.log "bash scan.sh"

set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "Usage: tmux-launch.sh <session-name> <gpi-label> [--log <path>] <command>" >&2
    exit 1
fi

SESSION="$1"
LABEL="$2"
shift 2

LOG_PATH=""
if [[ "${1:-}" == "--log" ]]; then
    LOG_PATH="$2"
    shift 2
fi

COMMAND="$1"

# Kill existing session with same name
# `-t=` forces EXACT match. Plain `-t` falls back to PREFIX match, so launching
# "job" while "job2" runs would kill "job2" (measured WSL 2026-09-17). CFG-616 family.
tmux kill-session -t="$SESSION" 2>/dev/null || true

# Pre-create log file with header (before tmux starts)
#
# CFG-659: the command text MUST NOT go into the log. Callers are told to append
# a completion sentinel to this same log (`echo 'RSYNC DONE' >> $log`), so a
# header echoing the command verbatim put the sentinel in the log at launch —
# `grep -c 'RSYNC DONE'` then returned 1 from the first second and reported a
# still-running job as complete. The sentinel matched the line that ANNOUNCED
# the sentinel. Same defect class as the CFG-597 pgrep self-match and the
# CFG-616 `tmux -t` prefix match: a check that matches its own invocation.
# The command goes to a `<log>.meta` sidecar; the log only points at it.
precreate_log() {
    local log="$1" session="$2" cmd="$3"
    mkdir -p "$(dirname "$log")"
    {
        echo "=== tmux-launch ==="
        echo "Session: $session"
        echo "Started: $(date -Iseconds)"
        echo "Command logged to: ${log}.meta"
        echo "==================="
        echo ""
    } > "$log"
    {
        echo "session: $session"
        echo "started: $(date -Iseconds)"
        echo "command: $cmd"
    } > "${log}.meta"
}

if [[ -n "$LOG_PATH" ]]; then
    precreate_log "$LOG_PATH" "$SESSION" "$COMMAND"
fi

# Register with GPI FIRST (the whole point of this wrapper)
GPI_ARGS=("$SESSION" "$LABEL")
[[ -n "$LOG_PATH" ]] && GPI_ARGS+=(--log "$LOG_PATH")
gpi start "${GPI_ARGS[@]}" 2>/dev/null || true

# Launch tmux with exit code capture
launch_session() {
    local session="$1" command="$2" log_path="$3"
    if [[ -n "$log_path" ]]; then
        # Capture real exit code via PIPESTATUS before tee masks it
        tmux new-session -d -s "$session" \
            "($command) 2>&1 | tee -a $log_path; _rc=\${PIPESTATUS[0]}; echo \"EXIT_CODE: \$_rc\" >> $log_path"
    else
        tmux new-session -d -s "$session" "$command"
    fi
}

launch_session "$SESSION" "$COMMAND" "$LOG_PATH"

# Verify session survived (detect immediate death)
verify_session() {
    local session="$1" log_path="$2"
    sleep 1
    # `-t=` (exact): with plain `-t`, a prefix-sharing sibling session would answer
    # for ours and mask the death we are checking for.
    if ! tmux has-session -t="$session" 2>/dev/null; then
        local msg="ERROR: tmux session '$session' died immediately"
        [[ -n "$log_path" ]] && msg="$msg. Check $log_path"
        echo "$msg" >&2
        if [[ -n "$log_path" ]]; then
            echo "" >> "$log_path"
            echo "ERROR: Session died immediately after launch" >> "$log_path"
        fi
        return 1
    fi
}

if ! verify_session "$SESSION" "$LOG_PATH"; then
    exit 1
fi

# Record the launch so a later kill can PROVE ownership (CFG-694). A tmux pane is a child
# of the TMUX SERVER, not of the session that asked for it, so this is the only place the
# ownership is still known. Best-effort: a failure here must never fail a launch.
_registry="${CONFIG_REPO:-$HOME/cfg-agent-fleet}/setup/scripts/launch-registry.sh"
if [[ -f "$_registry" ]]; then
    _pane_pid=$(tmux list-panes -t="$SESSION" -F '#{pane_pid}' 2>/dev/null | head -1)
    [[ -n "$_pane_pid" ]] && bash "$_registry" add "$_pane_pid" "tmux:$SESSION" "$COMMAND" 2>/dev/null || true
fi

echo "tmux '$SESSION' launched (GPI registered)"
