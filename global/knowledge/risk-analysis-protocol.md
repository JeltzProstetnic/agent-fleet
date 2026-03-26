<!-- consumed-by: global/CLAUDE.md (conditional loading trigger), global/hooks/risk-gate.sh (block message references this file) -->
# Risk Analysis Protocol for Infrastructure Changes

Loaded when `risk-gate.sh` blocks a Tier 1 edit. Follow this protocol to obtain clearance.

## Tier 1 File Inventory

| File Pattern | Blast Radius | Failure Mode |
|-------------|-------------|--------------|
| `~/.local/bin/mclaude` | All sessions on this machine | Launcher broken = no Claude Code access |
| `~/.local/bin/afleet` | AFD daemon, task coordination | Fleet coordination offline |
| `~/.cc-mirror/*/config/settings.json` | All hooks, permissions, statusline | Wrong permissions = lockout, broken hooks = silent failures |
| `~/.mcp.json` | All MCP integrations | Auth failures, tool unavailability (invisible until next restart) |
| `*/cfg-agent-fleet/sync.sh` | All deploy/collect operations | Broken sync = config divergence across machines |
| `*/agent-fleet/sync.sh` | Template propagation to all child projects | Stale templates, sync drift |

## Risk Subagent Prompt Template

Use this prompt when launching the risk analysis subagent:

```
Analyze the proposed edit to [FILE_PATH]. The edit will:
[DESCRIBE CHANGE]

Evaluate:
1. What breaks if this change has a bug? (blast radius)
2. Is the change reversible without manual intervention?
3. Are there dependent systems that need updating?
4. Does the change affect other machines via sync?
5. Is there a safer way to achieve the same goal?

Return: risk level (low/medium/high), specific concerns, and go/no-go recommendation.
Do NOT commit, push, or create PRs. Return findings as text.
```

## Clearance Protocol

After the risk subagent returns an acceptable assessment:

1. Review the subagent's findings
2. If risk is acceptable, write the clearance file:
   ```bash
   touch /tmp/.risk-gate-clearance-<HASH>
   ```
   The hash is per-file: `echo "<file_path>" | md5sum | cut -c1-16`
3. Proceed with the edit (clearance valid for 10 minutes)
4. After editing, verify the change works as intended

## Known Failure Modes

**settings.json corruption (2026-02):** A merge conflict in settings.json broke all hooks on the Steam Deck. Required manual SSH recovery. Root cause: no pre-deploy JSON validation. Fixed by pre-deploy checks.

**mclaude launcher path change (2026-03):** Editing mclaude without updating the cc-mirror npm path caused "module not found" on next launch. All sessions blocked until rollback.

**.mcp.json invisible breakage:** Changes to .mcp.json only take effect after restart. A bad edit appears to succeed but silently breaks all MCP tools in the next session.

**sync.sh self-modification:** Editing sync.sh while a deploy is running can corrupt the deploy mid-flight. Always edit in the repo, never the deployed copy.

## Bypass Policy

Never bypass risk-gate.sh by removing the hook. If the hook is blocking legitimate work:
1. Run the risk subagent protocol (even briefly)
2. Write the clearance file
3. Proceed with the edit

The 10-minute clearance window ensures each edit gets a fresh assessment.
