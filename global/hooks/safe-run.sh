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

# --- Run the hook, capturing stdout and stderr separately ---
# PreToolUse hooks use exit 2 + stderr to block tool calls.
# We must preserve that signal while still catching crashes.
_sr_tmp=$(mktemp /tmp/safe-run-stderr.XXXXXX)
_stdout=""
_stderr=""
_stdout=$(bash "$HOOK_PATH" "$@" 2>"$_sr_tmp") || {
  rc=$?
  _stderr=$(cat "$_sr_tmp" 2>/dev/null)
  rm -f "$_sr_tmp"
  if [[ $rc -eq 2 ]] && [[ -n "$_stderr" ]]; then
    # Deliberate block (PreToolUse convention) — pass through
    [[ -n "$_stdout" ]] && echo "$_stdout"
    echo "$_stderr" >&2
    exit 2
  fi
  # Unexpected failure — degrade gracefully
  [[ -n "$_stdout" ]] && echo "$_stdout"
  [[ -n "$_stderr" ]] && echo "$_stderr"
  echo "⚠ HOOK FAILED: $HOOK_NAME (exit $rc) — non-blocking"
  exit 0
}
rm -f "$_sr_tmp"

# --- Success: pass through output ---
[[ -n "$_stdout" ]] && echo "$_stdout"
exit 0
