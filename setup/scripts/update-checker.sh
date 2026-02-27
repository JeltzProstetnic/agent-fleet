#!/usr/bin/env bash
# cc-mirror update checker
# ========================
# Runs at mclaude startup (interactive sessions only).
# Checks for Claude Code updates once per day.

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

# Get installed version
NPM_DIR="$HOME/.cc-mirror/mclaude/npm"
INSTALLED=""
if [[ -f "$NPM_DIR/node_modules/@anthropic-ai/claude-code/package.json" ]]; then
  INSTALLED=$(node -e "console.log(require('$NPM_DIR/node_modules/@anthropic-ai/claude-code/package.json').version)" 2>/dev/null || echo "unknown")
fi

if [[ -z "$INSTALLED" || "$INSTALLED" == "unknown" ]]; then
  exit 0
fi

# Check latest version from npm registry (timeout 5s to not block startup)
LATEST=$(timeout 5 npm view @anthropic-ai/claude-code version 2>/dev/null || echo "")

mkdir -p "$(dirname "$UPDATE_MARKER")"
date +%s > "$UPDATE_MARKER"

if [[ -z "$LATEST" ]]; then
  # Network issue — skip silently
  exit 0
fi

if [[ "$INSTALLED" != "$LATEST" ]]; then
  echo -e "${YELLOW}Claude Code update available: ${INSTALLED} → ${LATEST}${NC}"
  echo -e "${BLUE}  Update: cd ~/.cc-mirror/mclaude/npm && npm update${NC}"
else
  echo -e "${GREEN}Claude Code ${INSTALLED} (latest)${NC}"
fi
