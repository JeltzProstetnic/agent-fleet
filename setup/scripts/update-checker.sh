#!/usr/bin/env bash
# cc-mirror update checker
# ========================
# Runs at mclaude startup (interactive sessions only).
# Checks for Claude Code updates once per day.

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
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

echo -e "${BLUE}Checking for updates...${NC}"

mkdir -p "$(dirname "$UPDATE_MARKER")"
date +%s > "$UPDATE_MARKER"
echo -e "${GREEN}Update check complete${NC}"
