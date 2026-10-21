#!/usr/bin/env bash
# playwright-value-guard.sh — PreToolUse on mcp__playwright__browser_evaluate and
# mcp__playwright__browser_run_code_unsafe (CFG-791).
#
# Incident 2026-10-21: a diagnostic read .value over every <input> on a page and
# returned a freshly generated password into the transcript (rotated before use).
# Refuses code that reads .value over a COLLECTION of inputs unless the code excludes
# type=password — via :not([type=password]) or a type !== 'password' filter.
# A single named input (querySelector('#email').value) is not a collection and passes.
# Exit 2 + stderr = block. Exit 0 = allow.

INPUT=$(cat)
[[ "$INPUT" == *'mcp__playwright__browser_evaluate'* || "$INPUT" == *'mcp__playwright__browser_run_code_unsafe'* ]] || exit 0

# Every string in tool_input (code / function / anything else that carries JS).
CODE=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
def walk(v):
    if isinstance(v, str): yield v
    elif isinstance(v, dict):
        for x in v.values(): yield from walk(x)
    elif isinstance(v, list):
        for x in v: yield from walk(x)
try:
    print("\n".join(walk(json.load(sys.stdin).get("tool_input", {}))))
except Exception:
    pass' 2>/dev/null)
[[ -n "$CODE" ]] || exit 0

# Reads a value at all?
grep -qE '\.value\b' <<< "$CODE" || exit 0

# Over a collection of inputs?
grep -qiE "querySelectorAll\([^)]*(input|textarea)|getElementsByTagName\([[:space:]]*['\"\`](input|textarea)|\.elements\b|\\\$\\\$\([[:space:]]*['\"\`][^'\"\`]*input" <<< "$CODE" || exit 0

# Passwords excluded?
grep -qiE ":not\([[:space:]]*\[[[:space:]]*type[[:space:]]*=[[:space:]]*['\"]?password|type[[:space:]]*!==?[[:space:]]*['\"\`]password|['\"\`]password['\"\`][[:space:]]*!==?[[:space:]]*[A-Za-z_\$][A-Za-z0-9_\$.]*\.type" <<< "$CODE" && exit 0

echo "BLOCKED (CFG-791): this code reads .value over a collection of inputs without excluding type=password — a password field's value would land in the transcript. Exclude it: querySelectorAll('input:not([type=password])') or .filter(i => i.type !== 'password'), or read the one field you need by selector." >&2
exit 2
