# Permissions Reference

Load this file when: subagent tool calls are being auto-denied, or setting up permissions for non-interactive use.

## Why Global Permissions Matter

Subagents (spawned by Claude Code during multi-step tasks) run non-interactively. They cannot prompt you to approve a tool call. If a permission is not pre-granted in `settings.json`, the call is auto-denied and the task silently fails or errors.

## Example settings.json Permissions Block

Located at `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(git:*)",
      "Bash(npm:*)",
      "Bash(npx:*)",
      "Read(**)",
      "Write(**)",
      "Edit(**)"
    ],
    "deny": []
  }
}
```

Adjust the `allow` list to match the tools your workflows actually use. Overly broad permissions are a security risk; overly narrow ones break subagents.

## Diagnosing "Permission auto-denied" Errors

1. Look for the phrase "auto-denied" or "permission" in the error output
2. Identify which tool call triggered it (Bash, Read, Write, Edit, mcp__)
3. Add the minimal matching pattern to the `allow` list
4. Restart Claude Code and retry

Pattern syntax: `ToolName(glob)` — e.g., `Bash(gh:*)` allows all `gh` subcommands.
