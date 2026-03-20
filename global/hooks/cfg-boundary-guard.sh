INPUT=$(cat)

if [[ "$INPUT" != *'"tool_name":"Write"'* && "$INPUT" != *'"tool_name": "Write"'* && \
      "$INPUT" != *'"tool_name":"Edit"'*  && "$INPUT" != *'"tool_name": "Edit"'* ]]; then
    exit 0
fi

FILE_PATH=""
if command -v jq &>/dev/null; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
else
    FILE_PATH=$(echo "$INPUT" | grep -oP '"file_path"\s*:\s*"([^"]*)"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
fi

[ -z "$FILE_PATH" ] && exit 0

RESOLVED_PATH="${FILE_PATH/#\~/$HOME}"

CLAUDE_DIR="$HOME/.claude/"
CFG_GLOBAL="$HOME/agent-fleet/global/"

IS_PROTECTED=false
if [[ "$RESOLVED_PATH" == "$CLAUDE_DIR"* ]] || [[ "$RESOLVED_PATH" == "$CFG_GLOBAL"* ]]; then
    IS_PROTECTED=true
fi

$IS_PROTECTED || exit 0

_PROJECT="${PROJECT_DIR:-$PWD}"

if [[ "$_PROJECT" == *"agent-fleet"* ]]; then
    exit 0
fi

echo "BLOCKED: ${FILE_PATH} is owned by agent-fleet. Create a cross-project inbox item instead of editing directly. Rule: ~/.claude/* and ~/agent-fleet/global/* are cfg-exclusive." >&2
exit 2
