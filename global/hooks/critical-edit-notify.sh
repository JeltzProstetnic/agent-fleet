#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null) || exit 0
case "$TOOL_NAME" in
    Write|Edit) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null) || exit 0
[ -n "$FILE_PATH" ] || exit 0

# Classify tier: T1 = critical infrastructure, T2 = deploy-sensitive
TIER=""
case "$FILE_PATH" in
    */.local/bin/mclaude)                TIER="T1" ;;
    */.local/bin/afleet)                 TIER="T1" ;;
    */.cc-mirror/*/config/settings.json) TIER="T1" ;;
    */.mcp.json)                         TIER="T1" ;;
    */agent-fleet/sync.sh)           TIER="T1" ;;
    */agent-fleet/sync.sh)               TIER="T1" ;;
    *agent-fleet/global/*)               TIER="T2" ;;
    *agent-fleet/setup/config/*)         TIER="T2" ;;
    *agent-fleet/setup/scripts/*)        TIER="T2" ;;
    */.claude/hooks/*)                   TIER="T2" ;;
    */.claude/foundation/*)              TIER="T2" ;;
    */.claude/reference/*)               TIER="T2" ;;
    */.claude/knowledge/*)               TIER="T2" ;;
    */.claude/domains/*)                 TIER="T2" ;;
    */.claude/CLAUDE.md)                 TIER="T2" ;;
    */.claude/statusline*)               TIER="T2" ;;
    */statusline-command.sh)             TIER="T2" ;;
esac

[ -n "$TIER" ] || exit 0

BASENAME=$(basename "$FILE_PATH")
if [ "$TIER" = "T1" ]; then
    MSG="TIER 1 — mandatory risk review: ${BASENAME} — commit immediately to prevent cross-machine divergence."
else
    MSG="TIER 2 — review recommended: ${BASENAME} — commit immediately to prevent cross-machine divergence."
fi

python3 -c "
import json, sys
print(json.dumps({'continue': True, 'additionalContext': sys.argv[1]}))
" "$MSG"
