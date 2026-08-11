#!/usr/bin/env bash
# PreToolUse hook: blocks Tier 1 infrastructure edits without risk clearance.
# T1 files: mclaude, afleet, settings.json, .mcp.json, sync.sh
# Clearance: /tmp/.risk-gate-clearance-<md5hash> (valid 10 minutes)
#
# Exit 0 = allow, Exit 2 + stderr = block with instructions.

# Drain stdin immediately (PreToolUse contract)
INPUT=$(cat)

# Fast exit: only process Write/Edit tools
if [[ "$INPUT" != *'"tool_name":"Write"'* && "$INPUT" != *'"tool_name": "Write"'* && \
      "$INPUT" != *'"tool_name":"Edit"'*  && "$INPUT" != *'"tool_name": "Edit"'* ]]; then
    exit 0
fi

# Extract file_path
FILE_PATH=""
if command -v jq &>/dev/null; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
else
    FILE_PATH=$(echo "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
fi
[ -z "$FILE_PATH" ] && exit 0

# Resolve ~ to $HOME
FILE_PATH="${FILE_PATH/#\~/$HOME}"

# Classify: Tier 1 only — everything else passes through
IS_T1=false
case "$FILE_PATH" in
    */.local/bin/mclaude)                   IS_T1=true ;;
    */.local/bin/afleet)                    IS_T1=true ;;
    */.cc-mirror/*/config/settings.json)    IS_T1=true ;;
    */.mcp.json)                            IS_T1=true ;;
    */agent-fleet/sync.sh)              IS_T1=true ;;
    */agent-fleet/sync.sh)                  IS_T1=true ;;
esac

$IS_T1 || exit 0

# Check clearance file (per-file, time-limited)
HASH=$(echo "$FILE_PATH" | md5sum | cut -c1-16)
CLEARANCE="/tmp/.risk-gate-clearance-${HASH}"

if [ -f "$CLEARANCE" ]; then
    FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$CLEARANCE" 2>/dev/null || echo 0) ))
    if [ "$FILE_AGE" -lt 600 ]; then
        exit 0
    fi
fi

# Block: no valid clearance
BASENAME=$(basename "$FILE_PATH")
cat >&2 <<EOF
RISK_GATE TIER 1 — Edit to $BASENAME blocked.
This is a critical infrastructure file. Before editing:
1. Load knowledge/risk-analysis-protocol.md
2. Launch a risk analysis subagent for this change
3. Write clearance file after acceptable assessment
Clearance file: $CLEARANCE
EOF
exit 2
