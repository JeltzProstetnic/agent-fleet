#!/usr/bin/env bash
# lib-hook-stdin.sh — read the CC session_id from a hook's stdin JSON (CFG-452 Phase 1).
#
# Claude Code pipes {"session_id":"...", ...} to SessionStart / SessionEnd hooks
# on stdin. Binding session-lock ownership to this id (instead of the inheritable
# AFLEET_SESSION_ID env var) closes the F1 spoof: a nested CC process (headless
# `mclaude -p` via the Bash tool, a tmux-launched background CC in the same
# project) inherits AFLEET_SESSION_ID but gets a DIFFERENT session_id, so its
# SessionEnd can no longer release the leader's live lock.
#
# SAFE BY CONSTRUCTION — any failure path yields "" and the caller falls back to
# legacy AFLEET_SESSION_ID ownership (i.e. pre-CFG-452 behaviour):
#   - TTY / no pipe            -> "" (nothing to read)
#   - empty or malformed JSON  -> ""
#   - python3 absent           -> grep/sed fallback, else ""
# NEVER BLOCKS: interactive stdin is skipped (`-t 0`) and the read is bounded by
# a 2s `timeout` so a SessionStart hang can never lock the user out.

# read_cc_session_id — reads and CONSUMES stdin once; echoes the session_id (or "").
# Call once, early, in a hook (typically: CC_SESSION_ID="$(read_cc_session_id)").
read_cc_session_id() {
    # Interactive shell / no piped input — nothing to read, don't block.
    [ -t 0 ] && return 0

    # Bounded read. Do NOT gate on the exit status: if `timeout` kills `cat`,
    # the JSON `cat` already echoed is still captured in $_raw.
    local _raw
    _raw="$(timeout 2 cat 2>/dev/null)"
    [ -n "$_raw" ] || return 0

    local _id=""
    if command -v python3 >/dev/null 2>&1; then
        _id="$(printf '%s' "$_raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = d.get("session_id", "") if isinstance(d, dict) else ""
    sys.stdout.write(v if isinstance(v, str) else "")
except Exception:
    pass' 2>/dev/null)"
    fi

    # Fallback: extract the field textually if python3 is absent or found nothing.
    if [ -z "$_id" ]; then
        _id="$(printf '%s' "$_raw" \
            | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -1 \
            | sed 's/.*"session_id"[[:space:]]*:[[:space:]]*"//; s/"$//')"
    fi

    printf '%s' "$_id"
}
