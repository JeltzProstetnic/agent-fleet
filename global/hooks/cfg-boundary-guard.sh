#!/usr/bin/env bash
INPUT=$(cat)

if [[ "$INPUT" != *'"tool_name":"Write"'* && "$INPUT" != *'"tool_name": "Write"'* && \
      "$INPUT" != *'"tool_name":"Edit"'*  && "$INPUT" != *'"tool_name": "Edit"'* ]]; then
    exit 0
fi

FILE_PATH=""
if command -v jq &>/dev/null; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
else
    FILE_PATH=$(echo "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
fi

[ -z "$FILE_PATH" ] && exit 0

RESOLVED_PATH="${FILE_PATH/#\~/$HOME}"

# Detect config repo dynamically (supports both agent-fleet and cfg-agent-fleet)
source "$(dirname "${BASH_SOURCE[0]}")/lib-detect-repo.sh" 2>/dev/null || true
CONFIG_REPO="${CONFIG_REPO:-$(_detect_config_repo 2>/dev/null || echo "$HOME/agent-fleet")}"
CONFIG_REPO_NAME="$(basename "$CONFIG_REPO")"

CLAUDE_DIR="$HOME/.claude/"
CFG_GLOBAL="$CONFIG_REPO/global/"

IS_PROTECTED=false
if [[ "$RESOLVED_PATH" == "$CLAUDE_DIR"* ]] || [[ "$RESOLVED_PATH" == "$CFG_GLOBAL"* ]]; then
    IS_PROTECTED=true
fi

$IS_PROTECTED || exit 0

# Allowlist: runtime state files that any project may write
CROSS_PROJECT_ALLOWLIST=(
    "$CLAUDE_DIR.active-persona"
)
for _allowed in "${CROSS_PROJECT_ALLOWLIST[@]}"; do
    [[ "$RESOLVED_PATH" == "$_allowed" ]] && exit 0
done

# Check if current project is cfg-agent-fleet
# For CONFIG_REPO/* paths: use CONFIG_REPO as the authoritative project identity
# For ~/.claude/* paths: use PROJECT_DIR/PWD (symlinks resolve to cfg, defeating git-based detection)
_PROJECT="${PROJECT_DIR:-$PWD}"
if [[ "$_PROJECT" == "$CONFIG_REPO" || "$_PROJECT" == "$CONFIG_REPO/"* ]]; then
    exit 0
fi

echo "BLOCKED: ${FILE_PATH} is owned by ${CONFIG_REPO_NAME}. Create a cross-project inbox item instead of editing directly. Rule: ~/.claude/* and ~/${CONFIG_REPO_NAME}/global/* are cfg-exclusive." >&2
exit 2
