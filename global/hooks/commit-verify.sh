#!/usr/bin/env bash
# PostToolUse hook: After git commit, remind to verify diff matches claims.
# Fires on Bash. Detects successful git commit by checking command + output pattern.
# Prevents commit messages that don't match actual changes.

set -euo pipefail

# _python3 (lib-portable.sh, CFG-1087): on native Windows a bare python3 can be the Microsoft Store
# stub; everywhere else it is python3, unchanged. Fallback for a hooks dir without the lib.
source "$(dirname "${BASH_SOURCE[0]}")/lib-portable.sh" 2>/dev/null || true
type _python3 >/dev/null 2>&1 || _python3() { python3 "$@"; }

INPUT=$(cat)

# Only process Bash
TOOL_NAME=$(echo "$INPUT" | _python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "Bash" ] || exit 0

# Extract command
COMMAND=$(echo "$INPUT" | _python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null) || exit 0

# Must contain "git" and "commit"
case "$COMMAND" in
    *git*commit*) ;;
    *) exit 0 ;;
esac

# Check output for successful commit pattern: [branch hash] message
# CFG-708: Claude Code sends the Bash result as tool_response.stdout; tool_output
# (read here before) is not in the payload, so this hook never fired.
STDOUT=$(echo "$INPUT" | _python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('tool_response') or d.get('tool_output') or {}
print(r.get('stdout', '') if isinstance(r, dict) else r)" 2>/dev/null) || exit 0

# Successful commits have "[branch hash]" in output
case "$STDOUT" in
    *\[*\]*) ;;
    *) exit 0 ;;
esac

_python3 -c "
import json, sys

msg = 'VERIFY COMMIT: Run git show --stat HEAD and confirm the diff contains all claimed changes. Narrative must match actual state.'

# Check if commit touches global/ — propagation reminder
stdout = sys.argv[1] if len(sys.argv) > 1 else ''
command = sys.argv[2] if len(sys.argv) > 2 else ''
if 'global/' in stdout or 'global/' in command:
    msg += ' | PROPAGATION: This commit touches global/ — check if template sync is needed.'

print(json.dumps({'continue': True, 'additionalContext': msg}))
" "$STDOUT" "$COMMAND"
