#!/usr/bin/env bash
# PostToolUse hook: detect tool installations and remind to update machine file.
# Fires on Bash. Detects pipx/pip/npm -g/pacman -S/apt install/flatpak install.
# Non-blocking — just an additionalContext reminder.

set -euo pipefail

INPUT=$(cat)

# Only process Bash
TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "Bash" ] || exit 0

# Extract command
COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null) || exit 0

# Check for install patterns
DETECTED=""
case "$COMMAND" in
    *"pipx install"*)      DETECTED="pipx" ;;
    *"pipx run"*)          exit 0 ;;  # pipx run is not an install
    *"pip install"*)       DETECTED="pip" ;;
    *"npm install -g"*|*"npm i -g"*) DETECTED="npm-global" ;;
    *"pacman -S"*)         DETECTED="pacman" ;;
    *"apt install"*|*"apt-get install"*) DETECTED="apt" ;;
    *"flatpak install"*)   DETECTED="flatpak" ;;
    *"cargo install"*)     DETECTED="cargo" ;;
    *) exit 0 ;;
esac

# Output reminder
python3 -c "
import json, sys
msg = f'TOOL_INSTALLED ({sys.argv[1]}): Update the machine file Installed Tooling table now. If cross-project boundary blocks the edit, create an inbox item.'
print(json.dumps({'continue': True, 'additionalContext': msg}))
" "$DETECTED"
