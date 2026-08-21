#!/usr/bin/env bash
# append-post-rotation.sh — Detect and record post-rotation commits in session-log
#
# Called by config-auto-sync.sh (SessionEnd hook, Phase 3.5).
# Can also be called standalone for testing.
#
# Usage: append-post-rotation.sh <project-dir>
#
# Reads .post-rotation-commit marker (written by rotate-session.sh).
# If commits exist after the recorded rotation point, appends them
# to the newest session-log entry under a **Post-shutdown:** heading.
# Cleans up the marker after processing.
#
# Safety: fails silently on any error (no data loss, no corruption).
# Uses same-directory tmpfiles for atomic mv.

set -euo pipefail

PROJECT_DIR="${1:-.}"
_MARKER="$PROJECT_DIR/.post-rotation-commit"
_LOG_FILE="$PROJECT_DIR/docs/session-log.md"

# Exit early if no marker
[[ -f "$_MARKER" ]] || exit 0

# Parse marker: "<hash> <unix_timestamp>"
_MARKER_CONTENT=$(cat "$_MARKER")
_ROTATION_HASH="${_MARKER_CONTENT%% *}"
_ROTATION_TS="${_MARKER_CONTENT##* }"

# Validate marker age — reject if older than 6 hours (stale from crashed session)
_MAX_AGE=21600  # 6 hours in seconds
_NOW=$(date +%s)
if [[ "$_ROTATION_TS" =~ ^[0-9]+$ ]]; then
    _AGE=$((_NOW - _ROTATION_TS))
    if [[ $_AGE -gt $_MAX_AGE ]]; then
        echo "Post-rotation marker is stale (${_AGE}s old, max ${_MAX_AGE}s) — removing without processing." >&2
        rm -f "$_MARKER"
        exit 0
    fi
else
    # Timestamp missing or invalid — legacy marker format, process anyway but warn
    echo "Post-rotation marker has no timestamp — processing but may be stale." >&2
fi

# Get current HEAD
_CURRENT_HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)
[[ -n "$_CURRENT_HEAD" ]] || { rm -f "$_MARKER"; exit 0; }

# No new commits? Clean up and exit
if [[ "$_ROTATION_HASH" == "$_CURRENT_HEAD" ]]; then
    rm -f "$_MARKER"
    exit 0
fi

# Validate rotation hash is a real commit
if ! git -C "$PROJECT_DIR" cat-file -t "$_ROTATION_HASH" &>/dev/null; then
    echo "Post-rotation marker hash invalid — removing." >&2
    rm -f "$_MARKER"
    exit 0
fi

# Get post-rotation commits (chronological order)
_POST_COMMITS=$(git -C "$PROJECT_DIR" log --oneline "$_ROTATION_HASH..$_CURRENT_HEAD" --reverse 2>/dev/null || true)
if [[ -z "$_POST_COMMITS" ]]; then
    rm -f "$_MARKER"
    exit 0
fi

# Session-log must exist
if [[ ! -f "$_LOG_FILE" ]]; then
    rm -f "$_MARKER"
    exit 0
fi

# Find the first ### entry (newest session)
_FIRST_ENTRY=$(grep -n '^### ' "$_LOG_FILE" | head -1 | cut -d: -f1 || true)
if [[ -z "$_FIRST_ENTRY" ]]; then
    rm -f "$_MARKER"
    exit 0
fi

# Find insertion point: before "**Pending at shutdown:**" or "**Key Decisions:**"
_INSERT_BEFORE=$(tail -n +"$_FIRST_ENTRY" "$_LOG_FILE" \
    | grep -n '^\*\*Pending at shutdown:\*\*\|^\*\*Key Decisions:\*\*' \
    | head -1 | cut -d: -f1 || true)

if [[ -n "$_INSERT_BEFORE" ]]; then
    _INSERT_LINE=$((_FIRST_ENTRY + _INSERT_BEFORE - 1))
else
    # Fallback: insert before the next ### entry (end of current entry)
    _NEXT_ENTRY=$(tail -n +"$((_FIRST_ENTRY + 1))" "$_LOG_FILE" | grep -n '^### ' | head -1 | cut -d: -f1 || true)
    if [[ -n "$_NEXT_ENTRY" ]]; then
        _INSERT_LINE=$((_FIRST_ENTRY + _NEXT_ENTRY))
    else
        # No next entry — append at end of file
        _INSERT_LINE=$(($(wc -l < "$_LOG_FILE") + 1))
    fi
fi

# Splice in the post-shutdown block (same-directory tmpfile for atomic mv)
_TMPLOG=$(mktemp "$PROJECT_DIR/docs/.session-log.tmp.XXXXXX")
{
    head -n $((_INSERT_LINE - 1)) "$_LOG_FILE"
    echo "**Post-shutdown:**"
    echo "$_POST_COMMITS" | while IFS= read -r _line; do
        echo "- $_line"
    done
    tail -n +"$_INSERT_LINE" "$_LOG_FILE"
} > "$_TMPLOG"

mv "$_TMPLOG" "$_LOG_FILE"

# Clean up marker
rm -f "$_MARKER"
