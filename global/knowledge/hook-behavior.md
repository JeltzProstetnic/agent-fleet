# Hook Behavior — Platform Findings

## UserPromptSubmit doesn't fire for interrupt messages
**Discovered:** 2026-03-07. When the user sends messages during agent execution (Agent tool subagents running), the `UserPromptSubmit` hook does NOT fire. It only fires for prompts submitted at the normal input line.

**Impact:** Any logic relying on UserPromptSubmit for real-time detection (e.g., AFK deactivation) needs a secondary mechanism.

**Workaround:** Write a timestamp marker file in UserPromptSubmit, check it from PreToolUse (which fires on every tool call including subagent calls). Compare timestamps to detect user activity that the prompt hook missed.

## PreToolUse hooks DO fire for subagent tool calls
**Confirmed:** 2026-03-07 via Claude Code docs/changelog. Subagent tool calls include `agent_id` and `agent_type` fields in hook input. Hooks can distinguish parent vs subagent calls.

## urandom pipe unreliable for fixed-length output
`head -c 100 /dev/urandom | tr -dc 'a-z' | head -c 4` can produce fewer than 4 chars if the 100 random bytes don't contain enough lowercase ASCII. Use `python3 -c "import random,string; print(''.join(random.choices(string.ascii_lowercase, k=4)))"` for reliable fixed-length random strings.

## VPS service naming
Systemd service names may not match the expected pattern. Always check with `ls /etc/systemd/system/<service>*` before restarting services.

## Known Platform Quirks

### PreToolUse hook protocol (CC 2.1.76+)

**Problem:** `"Bash"` matcher in PreToolUse hooks fires on ALL tool calls (Read, Glob, Grep, etc.), not just Bash. CC displays "PreToolUse:Bash hook error" in the UI for each invocation.

**Root cause:** Two separate issues:
1. `matcher: "Bash"` fires on all tools — CC generates dispatcher-level error for non-matching tools
2. `hookSpecificOutput` JSON format fails CC's Zod schema validation (`gN6` only accepts `{async: true}` or `{continue: boolean}`)

**CC command hook protocol (verified by reading cli.js source):**
- **Allow (pass through):** `exit 0` with EMPTY stdout — CC treats as `hook_success`, no UI noise
- **Block:** `exit 2` with reason on stderr — CC treats as blocking error
- **NEVER output `hookSpecificOutput` JSON** from command hooks — it fails the `gN6` Zod schema validation before reaching the `Vr8` parser that would handle it. The `hookSpecificOutput` format is for HTTP/callback hooks only.
- Non-zero exit (not 2) — `hook_non_blocking_error` (UI error noise)

**Fix:**
1. Changed matcher from `"Bash"` to `""` in settings.json — hooks self-filter by tool_name
2. Non-Bash tools: `exit 0` with no output (silent pass-through)
3. Bash tools (not AFK): `exit 0` with no output
4. Bash tools (AFK deny): `exit 2` with reason on stderr

**Critical lesson:** Cannot verify hook UI errors from inside a Claude session — errors appear in terminal UI but NOT in tool results returned to the LLM. Use external testing (VM, manual terminal check, test scripts) to verify.

**Performance:** Match-all means hooks fire on every tool call. The early-exit path for non-Bash tools adds ~0ms overhead (bash string match on already-read stdin, silent `exit 0`, no python3/jq spawn).

### Settings.json location

When using a CC mirror setup (e.g., `mclaude`), `CLAUDE_CONFIG_DIR` may point to a different directory than `~/.claude/`. CC reads `$CLAUDE_CONFIG_DIR/settings.json` — verify which file is actually live before editing. The default `~/.claude/settings.json` may be a dead file in mirror setups.
