#!/usr/bin/env bash
# tmux-launch.sh — Launch a tmux session with automatic GPI registration.
# Replaces raw `tmux new-session -d` for long-running ops.
#
# Usage: tmux-launch.sh <session-name> "<gpi-label>" [--log <path>] [--mem <SIZE>|none] "<command>"
#
# CFG-741: every job runs in its own user cgroup (systemd-run --user --scope) with
# MemoryMax and MemorySwapMax=0, so a runaway is OOM-killed instead of freezing the box
# (2026-10-07: an uncapped fan-out filled 48 GB + 16 GB swap, WSL hung ~40 min).
# Default cap: MemAvailable at launch minus 4 GiB, at most 75% of MemTotal, at least 1 GiB.
# --mem 16G sets it, --mem none opts out. No working user systemd -> runs uncapped + warning.
#
# Example:
#   tmux-launch.sh chaos-scan "Scanning _chaos" --log /tmp/scan.log "bash scan.sh"

set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "Usage: tmux-launch.sh <session-name> <gpi-label> [--log <path>] [--mem <SIZE>|none] <command>" >&2
    exit 1
fi

SESSION="$1"
LABEL="$2"
shift 2

# CFG-742: tmux forbids '.' and ':' in session names — the launch then reads as
# "session died immediately" with no hint why (seen 2026-10-07 with a name like "job-0.4").
if [[ "$SESSION" == *[.:]* ]]; then
    echo "tmux-launch: session name '$SESSION' may not contain '.' or ':' (tmux rejects them) — use e.g. '${SESSION//[.:]/-}'" >&2
    exit 2
fi

LOG_PATH=""
MEM=""
while [[ $# -gt 1 ]]; do
    case "$1" in
        --log) LOG_PATH="$2"; shift 2 ;;
        --mem) MEM="$2"; shift 2 ;;
        *) break ;;
    esac
done

COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
    echo "Usage: tmux-launch.sh <session-name> <gpi-label> [--log <path>] [--mem <SIZE>|none] <command>" >&2
    exit 1
fi
if [[ -n "$MEM" && "$MEM" != none && ! "$MEM" =~ ^[0-9]+[KMGT]?$ ]]; then
    echo "tmux-launch: --mem '$MEM' is not a size (e.g. 512M, 16G) or 'none'" >&2
    exit 2
fi

# default_mem_cap — MemAvailable - 4 GiB, capped at 75% of MemTotal, floor 1 GiB, in MiB
default_mem_cap() {
    local mi="${TMUX_LAUNCH_MEMINFO:-/proc/meminfo}" total avail cap ceil
    total=$(awk '/^MemTotal:/ {print $2}' "$mi" 2>/dev/null)
    avail=$(awk '/^MemAvailable:/ {print $2}' "$mi" 2>/dev/null)
    [[ -n "$total" && -n "$avail" ]] || return 1
    cap=$(( avail - 4194304 )); ceil=$(( total * 3 / 4 ))
    (( cap > ceil )) && cap=$ceil
    (( cap < 1048576 )) && cap=1048576
    echo "$(( cap / 1024 ))M"
}

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

# Wrap the job in a memory-capped user scope (CFG-741). The systemd-run path is resolved
# HERE and embedded: the pane runs in the tmux server's environment, not ours.
MEM_STATUS=""
if [[ "$MEM" != none ]]; then
    _sdrun="${TMUX_LAUNCH_SYSTEMD_RUN:-$(command -v systemd-run 2>/dev/null || true)}"
    [[ -z "$MEM" ]] && MEM=$(default_mem_cap || true)
    _probe=(); command -v timeout >/dev/null 2>&1 && _probe=(timeout 10)
    # systemd-run succeeding is not enough: without a delegated memory controller the
    # user manager accepts MemoryMax and silently does not enforce it.
    _uid=$(id -u)
    _ctl="${TMUX_LAUNCH_CGROUP_CONTROLLERS:-/sys/fs/cgroup/user.slice/user-$_uid.slice/user@$_uid.service/cgroup.controllers}"
    _delegated=1
    [[ -r "$_ctl" ]] && ! grep -qw memory "$_ctl" && _delegated=0
    if [[ -n "$MEM" && -n "$_sdrun" && $_delegated -eq 1 ]] && "${_probe[@]}" "$_sdrun" --user --scope -q -p MemoryMax=1G -- true >/dev/null 2>&1; then
        COMMAND="$_sdrun --user --scope -q -p MemoryMax=$MEM -p MemorySwapMax=0 -- bash -c $(printf '%q' "$COMMAND")"
        MEM_STATUS=", memory cap $MEM"
        [[ -n "$LOG_PATH" ]] && echo "memory_cap: $MEM" >> "${LOG_PATH}.meta"
    else
        _why="no working 'systemd-run --user'"; [[ $_delegated -eq 0 ]] && _why="memory controller not delegated to the user manager ($_ctl)"
        echo "WARNING: tmux-launch: $_why — '$SESSION' runs uncapped (a runaway can exhaust memory)" >&2
        MEM_STATUS=", uncapped"
        [[ -n "$LOG_PATH" ]] && echo "memory_cap: none ($_why)" >> "${LOG_PATH}.meta"
    fi
fi

# Register with GPI FIRST (the whole point of this wrapper)
# CFG-616: a failed registration must not fail the launch, but it must not be
# swallowed either — `2>/dev/null || true` plus an unconditional "GPI registered"
# reported success while the statusline never learned about the job.
GPI_ARGS=("$SESSION" "$LABEL")
[[ -n "$LOG_PATH" ]] && GPI_ARGS+=(--log "$LOG_PATH")
GPI_STATUS="GPI registered"
if ! _gpi_err=$(gpi start "${GPI_ARGS[@]}" 2>&1 >/dev/null); then
    GPI_STATUS="GPI registration FAILED"
    echo "WARNING: $GPI_STATUS for '$SESSION': ${_gpi_err:-gpi exited non-zero}" >&2
fi

# CFG-616 (candidate fix, UNVERIFIED — the backlog item stays open): start tmux
# through setsid. The first background job of a session died a few minutes in when no
# server was running (measured on WSL 2026-09-15). setsid only changes the tmux
# CLIENT's session: tmux daemonizes its server itself, and on Linux the server already
# has ppid 1 and its own session without setsid, so this is harmless but not a proven
# cure — what reaps the job on WSL is unexplained. `setsid tmux start-server` alone
# would be a no-op anyway: with the default `exit-empty on` an empty server exits at
# once. A script's children are never process-group leaders, so setsid runs tmux in
# place (no fork) and the exit status is preserved. Where setsid does not exist
# (macOS), plain tmux is the only option.
TMUX_CMD=(tmux)
command -v setsid >/dev/null 2>&1 && TMUX_CMD=(setsid tmux)

# Launch tmux with exit code capture
launch_session() {
    local session="$1" command="$2" log_path="$3"
    if [[ -n "$log_path" ]]; then
        # Capture real exit code via PIPESTATUS before tee masks it
        "${TMUX_CMD[@]}" new-session -d -s "$session" \
            "($command) 2>&1 | tee -a $log_path; _rc=\${PIPESTATUS[0]}; echo \"EXIT_CODE: \$_rc\" >> $log_path"
    else
        "${TMUX_CMD[@]}" new-session -d -s "$session" "$command"
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

echo "tmux '$SESSION' launched ($GPI_STATUS$MEM_STATUS)"
