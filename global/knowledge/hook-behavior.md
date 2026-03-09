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
