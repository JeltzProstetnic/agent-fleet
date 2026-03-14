#!/usr/bin/env bash
# session-lock.sh — PID-based session lock for same-machine protection (CFG-146)
#
# Library of functions for managing session locks. Source this file, then call:
#   acquire_lock <project_dir> [session_id]
#   release_lock <project_dir> [session_id]
#   check_lock <project_dir>
#   lock_info <project_dir>
#   force_release <project_dir>
#
# Lock file: $PROJECT_DIR/.claude/.session-lock (JSON, gitignored)
# Format: {"machine":"hostname","pid":12345,"sessionId":"abc","timestamp":"ISO8601","user":"name"}
#
# Return codes for check_lock:
#   0 = no lock (free) — also returned after stale lock auto-cleanup
#   1 = locked by us (our PID on this machine)
#   2 = locked by another session on this machine (different live PID)
#   3 = locked by another machine (can't verify PID — warn only)
#
# Hook integration points (DO NOT modify hooks yet — library must be proven first):
#   SessionStart hook → check_lock → if locked, inject warning into systemMessage
#   SessionEnd hook   → release_lock
#   Statusline hook   → periodic heartbeat (update timestamp in lock file)

# ── Helper: check if PID is alive ──────────────────────────────────────────

_is_pid_alive() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

# ── Helper: generate a pseudo-random session ID ────────────────────────────

_generate_session_id() {
    # Use /proc/sys/kernel/random/uuid if available, else fall back to date+random
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        printf "%s-%04x" "$(date +%s)" "$RANDOM"
    fi
}

# ── Helper: read lock file and parse JSON fields ───────────────────────────
# Sets global vars: _LOCK_MACHINE, _LOCK_PID, _LOCK_SESSION, _LOCK_TIMESTAMP, _LOCK_USER
# Returns 0 on success, 1 if file missing or invalid JSON

_read_lock() {
    local lockfile="$1"
    _LOCK_MACHINE="" _LOCK_PID="" _LOCK_SESSION="" _LOCK_TIMESTAMP="" _LOCK_USER=""

    [[ -f "$lockfile" ]] || return 1

    local json
    json=$(<"$lockfile")

    # Parse JSON using python3 (available on all fleet machines)
    local parsed
    parsed=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('machine',''))
    print(d.get('pid',''))
    print(d.get('sessionId',''))
    print(d.get('timestamp',''))
    print(d.get('user',''))
except:
    sys.exit(1)
" <<< "$json" 2>/dev/null) || return 1

    # Read parsed lines into variables
    {
        read -r _LOCK_MACHINE
        read -r _LOCK_PID
        read -r _LOCK_SESSION
        read -r _LOCK_TIMESTAMP
        read -r _LOCK_USER
    } <<< "$parsed"

    return 0
}

# ── Helper: write lock file ────────────────────────────────────────────────

_write_lock() {
    local lockfile="$1"
    local session_id="$2"

    local machine pid user timestamp
    machine="$(hostname)"
    pid="$$"
    user="$(whoami)"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    mkdir -p "$(dirname "$lockfile")"

    python3 -c "
import json
data = {
    'machine': '$machine',
    'pid': $pid,
    'sessionId': '$session_id',
    'timestamp': '$timestamp',
    'user': '$user'
}
print(json.dumps(data))
" > "$lockfile"
}

# ── acquire_lock ────────────────────────────────────────────────────────────
# Create lock file. If lock exists and PID alive on this machine, return error.
# If lock exists but PID dead (stale) or corrupt, auto-clean and acquire.
# session_id is optional (generates UUID-like if not provided).
# Returns: 0 = acquired, 1 = lock held by another live session

acquire_lock() {
    local project_dir="$1"
    local session_id="${2:-$(_generate_session_id)}"
    local lockfile="$project_dir/.claude/.session-lock"
    local lockdir="$project_dir/.claude/.session-lock.d"

    # Ensure .claude/ dir exists
    mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true

    # If lock file exists, check ownership before attempting acquire
    if [[ -f "$lockfile" ]]; then
        if ! _read_lock "$lockfile"; then
            # Corrupt lock — treat as stale, will overwrite below
            rm -f "$lockfile"
        else
            # Same session ID — idempotent re-acquire
            if [[ "$_LOCK_SESSION" == "$session_id" ]]; then
                _write_lock "$lockfile" "$session_id"
                return 0
            fi

            # Different machine — can't verify PID, refuse
            if [[ "$_LOCK_MACHINE" != "$(hostname)" ]]; then
                echo "Lock held by another machine: $_LOCK_MACHINE (session: $_LOCK_SESSION)" >&2
                return 1
            fi

            # Same machine — check if PID is alive
            if _is_pid_alive "$_LOCK_PID"; then
                echo "Lock held by live process PID=$_LOCK_PID (session: $_LOCK_SESSION)" >&2
                return 1
            fi

            # PID dead — stale lock, will overwrite below
            rm -f "$lockfile"
        fi
    fi

    # Atomic write: mkdir is atomic on POSIX — prevents concurrent acquires.
    # Only reached when lock file doesn't exist (free, stale-cleaned, or corrupt-cleaned).
    if mkdir "$lockdir" 2>/dev/null; then
        _write_lock "$lockfile" "$session_id"
        rmdir "$lockdir" 2>/dev/null || true
        return 0
    fi

    # mkdir failed — another session is writing the lock right now
    echo "Lock acquisition race lost — another session acquired first" >&2
    return 1
}

# ── release_lock ────────────────────────────────────────────────────────────
# Remove lock file. Only if we own it (check sessionId or PID).
# Returns: 0 = released or no lock, 1 = lock owned by someone else

release_lock() {
    local project_dir="$1"
    local session_id="${2:-}"
    local lockfile="$project_dir/.claude/.session-lock"

    # No lock — noop success
    if [[ ! -f "$lockfile" ]]; then
        return 0
    fi

    # Try to read lock
    if ! _read_lock "$lockfile"; then
        # Corrupt — just remove
        rm -f "$lockfile"
        return 0
    fi

    # If session_id provided, check it matches
    if [[ -n "$session_id" ]]; then
        if [[ "$_LOCK_SESSION" == "$session_id" ]]; then
            rm -f "$lockfile"
            return 0
        else
            echo "Lock owned by session $_LOCK_SESSION, not $session_id" >&2
            return 1
        fi
    fi

    # No session_id — check PID
    if [[ "$_LOCK_PID" == "$$" ]]; then
        rm -f "$lockfile"
        return 0
    fi

    echo "Lock owned by PID $_LOCK_PID, not $$" >&2
    return 1
}

# ── check_lock ──────────────────────────────────────────────────────────────
# Check if lock exists.
# Returns: 0 = free, 1 = locked by us, 2 = locked by another (same machine),
#          3 = locked by another machine

check_lock() {
    local project_dir="$1"
    local lockfile="$project_dir/.claude/.session-lock"

    # No lock file
    if [[ ! -f "$lockfile" ]]; then
        return 0
    fi

    # Try to read lock
    if ! _read_lock "$lockfile"; then
        # Corrupt — clean up, report free
        rm -f "$lockfile"
        return 0
    fi

    # Different machine — can't verify PID
    if [[ "$_LOCK_MACHINE" != "$(hostname)" ]]; then
        return 3
    fi

    # Same machine — check PID
    if ! _is_pid_alive "$_LOCK_PID"; then
        # Stale — auto-clean
        rm -f "$lockfile"
        return 0
    fi

    # PID alive — is it us?
    if [[ "$_LOCK_PID" == "$$" ]]; then
        return 1
    fi

    # Another live session on this machine
    return 2
}

# ── lock_info ───────────────────────────────────────────────────────────────
# Print lock contents as human-readable text

lock_info() {
    local project_dir="$1"
    local lockfile="$project_dir/.claude/.session-lock"

    if [[ ! -f "$lockfile" ]]; then
        echo "No lock — project is free"
        return 0
    fi

    if ! _read_lock "$lockfile"; then
        echo "Lock file exists but is corrupt"
        return 0
    fi

    echo "Session Lock:"
    echo "  Machine:    $_LOCK_MACHINE"
    echo "  PID:        $_LOCK_PID"
    echo "  Session ID: $_LOCK_SESSION"
    echo "  User:       $_LOCK_USER"
    echo "  Timestamp:  $_LOCK_TIMESTAMP"

    # Status check
    if [[ "$_LOCK_MACHINE" != "$(hostname)" ]]; then
        echo "  Status:     REMOTE (cannot verify PID)"
    elif _is_pid_alive "$_LOCK_PID"; then
        if [[ "$_LOCK_PID" == "$$" ]]; then
            echo "  Status:     ACTIVE (our session)"
        else
            echo "  Status:     ACTIVE (another session)"
        fi
    else
        echo "  Status:     STALE (PID dead)"
    fi
}

# ── force_release ───────────────────────────────────────────────────────────
# Force-remove lock regardless of owner (manual override)

force_release() {
    local project_dir="$1"
    local lockfile="$project_dir/.claude/.session-lock"

    rm -f "$lockfile"
    return 0
}
