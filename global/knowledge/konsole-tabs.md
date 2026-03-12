# Konsole Tab Management (KDE)

## Safety Rules

- **ALWAYS re-query `sessionList` before sending commands to ANY tab** — session IDs shift when tabs are closed/created. NEVER assume a session ID is still what you think it is.
- **Never send commands to a tab you didn't just create** without first verifying its title/identity.
- **Never rename a tab you didn't create** — `setTitle` on the wrong session clobbers the user's context.
- **"Project X is open" means HANDS OFF** — user is saying it's already running in another session. Don't touch it, don't open a second instance.
- **Never open a second mclaude instance for a project that's already running** — causes session conflicts, dual shutdowns, commit permission prompts.
- **When tab operations go wrong, STOP immediately.** Don't try to fix by sending more commands. Ask the user what state things are in.
- **Send cd and mclaude as separate Bash tool calls** — never compound them.
- **Bash permission matching is first-word only.** `Bash(qdbus:*)` only matches commands starting with `qdbus`. NEVER prefix with variable assignments — use literal values directly.
- **qdbus command pattern:** Always `qdbus org.kde.konsole-NNNNN /path method args` — never wrap in variables or subshells.

## D-Bus Commands

```bash
# Find running Konsole
KONSOLE_SVC=$(qdbus org.kde.konsole-* 2>/dev/null | head -1)
# Open new tab (returns session ID)
SID=$(qdbus "$KONSOLE_SVC" /Windows/1 org.kde.konsole.Window.newSession "tab-name" "bash")
# Send command to new tab (note trailing newline)
qdbus "$KONSOLE_SVC" /Sessions/$SID org.kde.konsole.Session.sendText "cd ~/project && mclaude
"
```
