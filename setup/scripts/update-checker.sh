#!/usr/bin/env bash
# cc-mirror update checker
# ========================
# Runs at mclaude startup (interactive sessions only).
# Checks for happy-coder updates once per day and re-applies
# the cc-mirror patch if needed.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

HAPPY_CODER_PATH="$HOME/.npm-global/lib/node_modules/happy-coder"
CLAUDE_VERSION_UTILS="$HAPPY_CODER_PATH/scripts/claude_version_utils.cjs"
PATCH_SCRIPT="$HOME/.cc-mirror/mclaude/scripts/happy-coder-patch.js"

# Skip if explicitly disabled
if [[ "${CC_MIRROR_SKIP_UPDATE:-0}" == "1" ]]; then
  exit 0
fi

# Only check once per day (unless forced)
UPDATE_MARKER="$HOME/.cc-mirror/.last-update-check"
if [[ -f "$UPDATE_MARKER" ]] && [[ "${CC_MIRROR_FORCE_UPDATE:-0}" != "1" ]]; then
  LAST_CHECK=$(cat "$UPDATE_MARKER" 2>/dev/null || echo "0")
  NOW=$(date +%s)
  if (( NOW - LAST_CHECK < 86400 )); then
    exit 0
  fi
fi

echo -e "${BLUE}Checking for updates...${NC}"

check_happy_coder_modified() {
  [[ -f "$CLAUDE_VERSION_UTILS" ]] && grep -q "findCcMirrorCliPath" "$CLAUDE_VERSION_UTILS" 2>/dev/null \
    && [[ -f "$HAPPY_CODER_PATH/bin/happy.mjs" ]] && grep -q "cc-mirror" "$HAPPY_CODER_PATH/bin/happy.mjs" 2>/dev/null
}

apply_patch() {
  if [[ -f "$PATCH_SCRIPT" ]] && [[ -f "$CLAUDE_VERSION_UTILS" ]]; then
    echo -e "${BLUE}Applying cc-mirror patch to happy-coder...${NC}"
    node "$PATCH_SCRIPT" "$CLAUDE_VERSION_UTILS" && echo -e "${GREEN}Patch applied${NC}"
  fi
}

# Check for happy-coder updates
if [[ -d "$HAPPY_CODER_PATH" ]]; then
  CURRENT=$(node -p "require('$HAPPY_CODER_PATH/package.json').version" 2>/dev/null || echo "0.0.0")
  LATEST=$(npm view happy-coder version 2>/dev/null || echo "$CURRENT")

  if [[ "$CURRENT" != "$LATEST" ]]; then
    echo -e "${YELLOW}Updating happy-coder: $CURRENT -> $LATEST${NC}"
    npm install -g happy-coder 2>/dev/null && apply_patch
  elif ! check_happy_coder_modified; then
    apply_patch
  fi
fi

mkdir -p "$(dirname "$UPDATE_MARKER")"
date +%s > "$UPDATE_MARKER"
echo -e "${GREEN}Update check complete${NC}"
