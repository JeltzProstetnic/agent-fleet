set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null) || exit 0
case "$TOOL_NAME" in
    Write|Edit) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null) || exit 0
[ -n "$FILE_PATH" ] || exit 0

SENSITIVE=false
case "$FILE_PATH" in
    */agent-fleet/global/*) SENSITIVE=true ;;
    */agent-fleet/setup/config/*) SENSITIVE=true ;;
    */agent-fleet/setup/scripts/*) SENSITIVE=true ;;
    */.claude/hooks/*) SENSITIVE=true ;;
    */.claude/foundation/*) SENSITIVE=true ;;
    */.claude/reference/*) SENSITIVE=true ;;
    */.claude/knowledge/*) SENSITIVE=true ;;
    */.claude/domains/*) SENSITIVE=true ;;
    */.claude/CLAUDE.md) SENSITIVE=true ;;
    */.claude/statusline*) SENSITIVE=true ;;
    */statusline-command.sh) SENSITIVE=true ;;
esac

[ "$SENSITIVE" = "true" ] || exit 0

BASENAME=$(basename "$FILE_PATH")
python3 -c "
import json, sys
msg = f'DEPLOY-SENSITIVE EDIT: {sys.argv[1]} — commit immediately to prevent cross-machine divergence.'
print(json.dumps({'continue': True, 'systemMessage': msg}))
" "$BASENAME"
