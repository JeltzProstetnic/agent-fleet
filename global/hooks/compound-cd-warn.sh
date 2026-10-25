#!/usr/bin/env bash
# PreToolUse hook: BLOCK (exit 2) `cd <dir> && <cmd>` / `cd <dir>; <cmd>`.
#
# CFG-602: the global rule "No compound cd commands — use git -C <path> or absolute
# paths" was broken 65 times in one session because nothing fired. A warning
# (2026-09-28) changed nothing — it arrives after the command ran — so CFG-810
# (owner, 2026-10-25) blocks and names the alternatives. The filename keeps "warn"
# so no settings.json registration has to change.
#
# Exit 0 with empty stdout everywhere else, so there is no UI noise.

INPUT=$(cat)

case "$INPUT" in
    *'"tool_name":"Bash"'*|*'"tool_name": "Bash"'*) ;;
    *) exit 0 ;;
esac

CMD=$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception: pass' 2>/dev/null)
[ -n "$CMD" ] || exit 0

# `cd` as a command word (start, or after ; & | ( ), with an argument, then a
# chaining operator and another command. A bare `cd <dir>` is not a chain.
if ! printf '%s' "$CMD" | grep -qE '(^|[;&|(])[[:space:]]*cd[[:space:]]+[^;&|]+(&&|;)[[:space:]]*[^[:space:]]'; then
    exit 0
fi

echo 'compound-cd-warn (CFG-602/CFG-810): BLOCKED — this command chains `cd <dir>` with another command. Rewrite it: `git -C <path> …`, absolute paths, or `env -C <dir> <cmd>` for a tool that needs its working directory (e.g. a Windows .exe from a /mnt cwd).' >&2
exit 2
