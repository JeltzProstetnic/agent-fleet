#!/usr/bin/env bash
# PostToolUse hook: auto-lint files after Write/Edit.
# Runs language-specific syntax checks and reports errors via systemMessage.
# Uses only always-available tools (bash -n, python3, node --check).
# Non-blocking — errors are advisory, never prevent the tool from completing.

set -euo pipefail

# Read stdin (JSON from Claude Code PostToolUse event)
INPUT=$(cat)

# Extract tool name — only process Write and Edit
TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null) || exit 0
case "$TOOL_NAME" in
    Write|Edit) ;;
    *) exit 0 ;;
esac

# Extract file path
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null) || exit 0
[ -n "$FILE_PATH" ] && [ -f "$FILE_PATH" ] || exit 0

# Determine file type and run appropriate linter
LINT_OUTPUT=""
BASENAME=$(basename "$FILE_PATH")
EXT="${BASENAME##*.}"

case "$EXT" in
    sh|bash)
        LINT_OUTPUT=$(bash -n "$FILE_PATH" 2>&1) || true
        ;;
    py)
        LINT_OUTPUT=$(python3 -m py_compile "$FILE_PATH" 2>&1) || true
        # py_compile creates .pyc files — clean up
        rm -f "${FILE_PATH}c" 2>/dev/null
        rm -rf "__pycache__" 2>/dev/null
        ;;
    json)
        LINT_OUTPUT=$(python3 -c "import json; json.load(open('$FILE_PATH'))" 2>&1) || true
        ;;
    js|mjs)
        if command -v node >/dev/null 2>&1; then
            LINT_OUTPUT=$(node --check "$FILE_PATH" 2>&1) || true
        fi
        ;;
esac

# If no lint errors, exit silently
[ -n "$LINT_OUTPUT" ] || exit 0

# Output JSON with additionalContext for Claude
python3 -c "
import json, sys
msg = f'Auto-lint ({sys.argv[1]}): {sys.argv[2]}'
print(json.dumps({'continue': True, 'additionalContext': msg}))
" "$BASENAME" "$LINT_OUTPUT"
