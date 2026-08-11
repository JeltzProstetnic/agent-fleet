#!/usr/bin/env bash
# PreToolUse hook: block cmd.exe/multipass/powershell.exe calls from UNC paths.
# WSL maps non-/mnt/ paths to \\wsl.localhost\ which cmd.exe rejects.
# Exit 2 = block with message. Exit 0 = allow.
INPUT=$(cat)

# Only care about Bash tool
if [[ "$INPUT" != *'"tool_name":"Bash"'* && "$INPUT" != *'"tool_name": "Bash"'* ]]; then
    exit 0
fi

# Extract command
CMD=""
if command -v jq &>/dev/null; then
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
    CMD=$(echo "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"command"[^"]*"\([^"]*\)"/\1/')
fi

[ -z "$CMD" ] && exit 0

# Extract the first executable token (skip env var assignments like VAR=x)
FIRST_CMD=$(echo "$CMD" | sed 's/^[[:space:]]*//' | sed 's/^[A-Za-z_][A-Za-z_0-9]*=[^ ]* *//' | awk '{print $1}')

# Check if the first command is a Windows executable
case "$FIRST_CMD" in
    cmd.exe|multipass|powershell.exe|PowerShell|pwsh) ;;
    *) exit 0 ;;
esac

# Allow if CWD is already a Windows-native path
if [[ "$PWD" == /mnt/* ]]; then
    exit 0
fi

echo "BLOCKED: CWD is $PWD (UNC path). Windows executables need a /mnt/ path. Use: pushd /mnt/c/Users/\$(whoami) > /dev/null && <command>; popd > /dev/null" >&2
exit 2
