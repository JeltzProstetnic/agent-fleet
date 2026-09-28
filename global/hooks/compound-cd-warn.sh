#!/usr/bin/env bash
# PreToolUse hook: WARN (never block) on `cd <dir> && <cmd>` / `cd <dir>; <cmd>`.
#
# CFG-602: the global rule "No compound cd commands — use git -C <path> or absolute
# paths" was broken 65 times in one session because nothing fired. The owner chose
# (2026-09-28) to keep the rule and warn mechanically at the point of action.
#
# Warn = exit 0 + hookSpecificOutput.additionalContext (PreToolUse accepts it
# since CC 2.1.170 — see knowledge/hook-behavior.md). Exit 0 with empty stdout
# everywhere else, so there is no UI noise.

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

MSG='compound-cd-warn (CFG-602): this command chains `cd <dir>` with another command. Fleet rule: no compound `cd` — use `git -C <path>` or absolute paths instead. Not blocked; fix the form next time.'
python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":sys.argv[1]}}))' "$MSG"
exit 0
