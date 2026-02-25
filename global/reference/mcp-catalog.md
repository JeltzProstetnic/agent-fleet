# MCP Server Catalog

Load this file when: setting up MCP tools, debugging tool availability, or adding a new MCP server.

## GitHub MCP Server

The most common MCP server. Provides issue, PR, repo, and code search tools.

Install:
```bash
npm install -g @modelcontextprotocol/server-github
```

Add to `~/.claude/settings.json`:
```json
{
  "mcpServers": {
    "github": {
      "command": "mcp-server-github",
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_yourtoken"
      }
    }
  }
}
```

**Key gotcha:** The env var MUST be `GITHUB_PERSONAL_ACCESS_TOKEN`, not `GITHUB_TOKEN`. Using the wrong name causes silent auth failures — tools appear but return permission errors.

## Adding a New MCP Server

1. Install the server package (npm, pip, or binary)
2. Add an entry under `mcpServers` in `~/.claude/settings.json`
3. Restart Claude Code
4. Verify with `/mcp` — server should appear as connected
5. Document the server in this catalog with its trigger condition

## Troubleshooting

**Server won't start:**
- Check the `command` value resolves on your PATH: `which mcp-server-github`
- Check for missing env vars — most servers fail silently on bad credentials
- Run the command manually in a terminal to see raw error output

**Tools not appearing:**
- Confirm the server shows "connected" in `/mcp`
- Some servers require specific scopes on their API token
- Check Claude Code logs: `~/.claude/logs/` (if present)
