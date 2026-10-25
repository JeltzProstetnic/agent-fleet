<!-- updates: reference/mcp-catalog.md -->
<!-- consumed-by: reference/mcp-catalog.md (config architecture and troubleshooting) -->
# MCP Configuration & Troubleshooting

Loaded on demand from `reference/mcp-catalog.md`. Quick routing table and gotchas are in the parent file.

---

## MCP Configuration Architecture

**Getting this wrong breaks MCP server discovery.** Three separate files, each with a distinct role:

| What | Where | NOT Here |
|------|-------|----------|
| Server definitions (command, args, env) | `.mcp.json` files | ~~settings.json~~, ~~.claude.json~~ |
| Server enablement flags | `settings.local.json` | ~~.claude.json~~ |
| Env vars, permissions, plugins | `settings.json` | |

**IMPORTANT:** Claude Code also reads `mcpServers` from `.claude.json` — but do NOT put servers there. `.claude.json` is owned by Claude Code (it overwrites it). Use `.mcp.json` exclusively. If you find servers in `.claude.json`, migrate them to `.mcp.json` and delete the `mcpServers` key from `.claude.json`.

### File format requirements

- **`.mcp.json`** must have the `mcpServers` wrapper:
  ```json
  { "mcpServers": { "server-name": { "command": "...", "args": [...], "env": {...} } } }
  ```

- **`settings.local.json`** needs BOTH flags:
  - `enableAllProjectMcpServers: true`
  - `enabledMcpjsonServers: [...]` (list of server names)

- **CRITICAL: `enabledMcpjsonServers` is a WHITELIST that filters ALL servers** — including servers from `~/.mcp.json` (global). If a server exists in `~/.mcp.json` but is NOT listed in the project's `enabledMcpjsonServers`, it will silently fail to connect. The server process may even start, but the MCP handshake never completes. Symptom: `mcp__servername__*` tools simply don't appear. Fix: add the server name to `enabledMcpjsonServers` in every project's `settings.local.json`.

- **CRITICAL: `permissions` blocks in `settings.local.json` REPLACE (not extend) global permissions.** Claude Code's "Always allow" button pollutes this file with random one-off approvals, destroying the comprehensive global permission set. The SessionStart hook `config-check.sh` (Check 10) auto-removes these blocks. See `~/.claude/knowledge/claude-code-permissions.md`.

- The **mclaude launcher auto-patches** `settings.local.json` before every startup, so MCP servers work in ALL projects without manual enablement.

### Key file locations

| File | Path |
|------|------|
| Canonical server definitions | `~/.cc-mirror/mclaude/config/.mcp.json` |
| Global copy (synced by launcher) | `~/.mcp.json` |
| Enablement flags | `~/.cc-mirror/mclaude/config/.claude/settings.local.json` |
| Settings (env, permissions, plugins) | `~/.cc-mirror/mclaude/config/settings.json` |

### Project-level overrides

Claude Code walks up from the project directory looking for `.mcp.json`. A project-level copy takes precedence over `~/.mcp.json`. The mclaude launcher syncs the canonical config to `~/.mcp.json` but does NOT update project-level copies.

**If MCP tools aren't available in a session**, the servers may have failed to start. Check by restarting mclaude or reviewing startup output.

---

## Troubleshooting: GitHub "Not Found" on Private Repos

**Most likely cause: wrong env var name.** The `@modelcontextprotocol/server-github` reads `GITHUB_PERSONAL_ACCESS_TOKEN`, NOT `GITHUB_TOKEN`. With the wrong name, the server runs unauthenticated — public repos work, private repos return 404.

**Quick diagnostic:**

1. Try `list_issues` on a **public** repo (e.g. `octocat/Hello-World`). If public works but private fails:
   - **Wrong env var name in `.mcp.json`.** Fix: change `"GITHUB_TOKEN"` to `"GITHUB_PERSONAL_ACCESS_TOKEN"` in both `~/.cc-mirror/mclaude/config/.mcp.json` and `~/.mcp.json`, then restart.

2. **Check for project-level `.mcp.json` override.** If a project has its own `.mcp.json` with the old `GITHUB_TOKEN` name, it silently overrides the fixed global config:
   ```bash
   ls <project>/.mcp.json   # if it exists, verify the env var name
   ```

3. If public repos also fail: server process issue. Check the token and restart mclaude.

**Do NOT waste time on stale-token diagnosis if the user already restarted.** Check the env var name first, then check for project-level `.mcp.json` overrides.

---

## Troubleshooting: Token & Auth Issues

**MCP servers cache env vars at startup.** After token changes in `.mcp.json`, you MUST restart mclaude.

**If restarting doesn't help**, test the token directly:

```bash
TOKEN=$(python3 -c "import json; d=json.load(open('$HOME/.cc-mirror/mclaude/config/.mcp.json')); print(d['mcpServers']['github']['env'].get('GITHUB_PERSONAL_ACCESS_TOKEN', d['mcpServers']['github']['env'].get('GITHUB_TOKEN', 'MISSING')))")
curl -sI -H "Authorization: token $TOKEN" https://api.github.com/user | grep x-oauth-scopes
```

- Scopes should include `repo`. If missing, regenerate the PAT.
- If curl works but MCP doesn't: check the env var name (see GitHub troubleshooting above).

---

## General Notes

- **Restart after any `.mcp.json` change.** MCP servers cache env vars at startup.
- **Do NOT embed tokens in documentation.** Reference `.mcp.json` for all credentials.
- **MCP servers are currently global**, not per-project. Roster changes require editing `.mcp.json` and restarting.
- **Irrelevant servers waste context** — their tool descriptions are loaded even when unused. Consider which servers are relevant per session type.
- **Operational knowledge files** exist for tools with complex bugs/workarounds: see `~/.claude/knowledge/` (e.g., `jira-atlassian.md` for mcp-atlassian patch procedure).
