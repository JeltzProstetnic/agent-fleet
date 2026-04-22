<!-- updates: (none currently) -->
<!-- consumed-by: global/hooks/context-budget.sh (injects LIVE_ISSUE_DETECTED on trigger-phrase match), global/CLAUDE.md (conditional loading trigger) -->
# Live-Issue Capture (CFG-389)

When the user reports a problem happening **now** — not after the fact — the live reproducer dies the moment they move on. Deferring state capture ("I'll check if it recurs") is wasted effort; the context is already gone hours later.

## Trigger phrases

Present-tense failure reports:
- "is stuck" / "got stuck" / "the session is stuck"
- "is hanging" / "is hung" / "won't respond" / "isn't responding"
- "can't dismiss" / "can't close" (modal/overlay)
- "failed to load" / "fails to load" / "won't load"
- "crashed" / "just crashed" (present/recent tense)
- "popup error" / "error popup"
- Any bracketed error text the user pastes with no other context

The `context-budget.sh` UserPromptSubmit hook injects `LIVE_ISSUE_DETECTED: capture state synchronously, then delegate.` when these patterns match. If you see that marker, follow the protocol below **in the same turn** — do not defer.

## Protocol — two actions, same turn

### 1. Capture live state synchronously (main thread)

Run everything relevant to the failure type. Examples by symptom:

| Symptom | Capture |
|---------|---------|
| Session/process stuck | `ps -ef \| grep <proc>`, `cat /tmp/<proc>.pid`, `ls -la /tmp/<proc>*` |
| Server unresponsive | `curl -sv <url>`, `journalctl -u <svc> --since "5 min ago"`, `ss -tlnp \| grep <port>` |
| UI hang (overlay/modal) | relevant log tail, browser console dump if reachable, screenshot if user offers |
| DB stuck | `sqlite3 <db> ".schema"`, row counts on relevant tables, locks check |
| API 4xx/5xx | exact response body, request headers, timestamp match in server log |
| Service won't start | `systemctl status`, `journalctl -xeu <svc>`, recent config diff |

**Rule:** capture is read-only and fast (under ~10 seconds of tool time). Write the captured state to `tmp/live-capture-<timestamp>.txt` or inline in the subagent prompt. Do not restart/kill/fix from the main thread — that destroys the reproducer.

### 2. Delegate investigation to a subagent

Pass the captured state verbatim in the subagent prompt. Example structure:

```
Context: user reports <symptom> happening RIGHT NOW.
Captured state (from <timestamp>):
<paste ps/logs/curl output>

Task: identify root cause and propose fix. Main thread continues other work.
Do NOT interact with live services — analyze the captured state only.
```

The main thread reports the capture + delegation to the user in one sentence ("captured process state, investigating in subagent — continuing other work"), then resumes. The subagent returns findings when done; user decides whether to act.

## Anti-patterns

- "If it happens again, let me know" → the reproducer is already gone; capture NOW
- "Let me restart the service to see if it clears" → destroys the live state
- Going deep on the problem in the main thread → derails whatever else was in flight
- Subagent hitting live services (see CLAUDE.md "Subagent isolation") → capture first, analyze text second

## Why same turn

Users report live issues once. If the main thread finishes some other task first and then circles back, the processes are gone, logs have rotated, PIDs are reused. Same-turn capture is the only reliable window.
