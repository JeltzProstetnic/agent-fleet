#!/usr/bin/env bash
# PostToolUse hook: After git commit, remind to verify diff matches claims.
# Fires on Bash. Detects successful git commit by checking command + output pattern.
# Prevents commit messages that don't match actual changes.

set -euo pipefail

INPUT=$(cat)

# Only process Bash
TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "Bash" ] || exit 0

# Extract command
COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null) || exit 0

# Must contain "git" and "commit"
case "$COMMAND" in
    *git*commit*) ;;
    *) exit 0 ;;
esac

# Check output for successful commit pattern: [branch hash] message
STDOUT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_output',{}).get('stdout',''))" 2>/dev/null) || exit 0

# Successful commits have "[branch hash]" in output
case "$STDOUT" in
    *\[*\]*) ;;
    *) exit 0 ;;
esac

python3 -c "
import json, sys

msg = 'VERIFY COMMIT: Run git show --stat HEAD and confirm the diff contains all claimed changes. Narrative must match actual state.'

# Check if commit touches global/ — propagation reminder
stdout = sys.argv[1] if len(sys.argv) > 1 else ''
command = sys.argv[2] if len(sys.argv) > 2 else ''
if 'global/' in stdout or 'global/' in command:
    msg += ' | PROPAGATION: This commit touches global/ — check if template sync is needed.'

print(json.dumps({'continue': True, 'systemMessage': msg}))
" "$STDOUT" "$COMMAND"
