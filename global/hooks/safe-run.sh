#!/usr/bin/env bash
# Hook safety wrapper — prevents hook failures from blocking Claude Code.
# ARCHITECTURE: All hooks in settings.json route through this script.
# A broken hook degrades gracefully (warning in context) instead of locking out the user.
#
# Usage in settings.json:
#   "command": "bash ~/.claude/hooks/safe-run.sh <hook-name>.sh [args...]"

set +e

HOOK_NAME="${1:?Usage: safe-run.sh <hook-script> [args...]}"
HOOK_PATH="$HOME/.claude/hooks/$HOOK_NAME"
shift

# --- Guard: hook must exist ---
if [[ ! -f "$HOOK_PATH" ]]; then
  echo "⚠ HOOK MISSING: $HOOK_NAME — skipping"
  exit 0
fi

# --- Guard: syntax check (catches merge conflicts, typos) ---
if ! bash -n "$HOOK_PATH" 2>/dev/null; then
  echo "⚠ HOOK SYNTAX ERROR: $HOOK_NAME — skipping (run 'bash -n ~/.claude/hooks/$HOOK_NAME' to debug)"
  exit 0
fi

# --- Run with error trap ---
output=$(bash "$HOOK_PATH" "$@" 2>&1) || {
  rc=$?
  # Print whatever output the hook produced before failing
  [[ -n "$output" ]] && echo "$output"
  echo "⚠ HOOK FAILED: $HOOK_NAME (exit $rc) — non-blocking"
  exit 0
}

# --- Success: pass through output ---
[[ -n "$output" ]] && echo "$output"
exit 0
