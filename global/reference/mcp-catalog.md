# MCP Server Catalog — Operational Reference

**MCP config location:** `~/.claude/.mcp.json` (or `~/.cc-mirror/<variant>/config/.mcp.json` for cc-mirror users)

Do NOT embed tokens in this file. All credentials live in `.mcp.json`.

---

## Active Servers

### 1. GitHub

| Field | Value |
|-------|-------|
| **Package** | `@modelcontextprotocol/server-github` |
| **Command** | `npx -y @modelcontextprotocol/server-github` |
| **Purpose** | GitHub operations: repos, issues, PRs, code search |
| **Env var** | `GITHUB_PERSONAL_ACCESS_TOKEN` |

**Key gotchas:**
- **CRITICAL:** The env var MUST be `GITHUB_PERSONAL_ACCESS_TOKEN`, NOT `GITHUB_TOKEN`. Using the wrong name causes unauthenticated requests — public repos work, private repos return 404.
- Project-level `.mcp.json` files override the global config. Claude Code walks up from the project dir looking for `.mcp.json`.
- Token scope must include `repo`. Test with: `curl -sI -H "Authorization: token $TOKEN" https://api.github.com/user | grep x-oauth-scopes`

### 2. Google Workspace

| Field | Value |
|-------|-------|
| **Package** | `workspace-mcp` (via `uvx`) |
| **Command** | `uvx workspace-mcp` |
| **Purpose** | Gmail, Google Docs, Sheets, Calendar, Drive, Contacts, Tasks, Forms, Presentations |
| **Auth** | OAuth (client ID + secret + email in `.mcp.json`) |

**Key gotchas:**
- Requires a Google Cloud project with OAuth 2.0 credentials and the relevant APIs enabled.
- The `USER_GOOGLE_EMAIL` field determines which Google account is used.
- OAuth tokens may expire. If auth fails, may need to re-authorize via browser.
- First run may require a browser-based consent flow to generate a refresh token.

### 3. Twitter/X

| Field | Value |
|-------|-------|
| **Package** | `@enescinar/twitter-mcp` |
| **Command** | `npx -y @enescinar/twitter-mcp` |
| **Purpose** | Post tweets, search tweets |
| **Auth** | API key + secret, access token + secret (in `.mcp.json`) |

**Key gotchas:**
- **NEVER post tweets autonomously.** Always get explicit user approval before calling `post_tweet`.
- Available tools: `post_tweet`, `search_tweets`.
- Rate limits and available features depend on your Twitter API tier (Free, Basic, Pro).
- Free tier: `search_tweets` may not work (returns 402). `post_tweet` works within monthly caps.

### 4. Jira/Atlassian

| Field | Value |
|-------|-------|
| **Package** | `mcp-atlassian` (via `uvx`) |
| **Command** | `uvx mcp-atlassian` |
| **Purpose** | Jira issues, projects, boards, sprints; Confluence pages |
| **Auth** | Instance URL + email + API token (in `.mcp.json`) |

**Parameter quirks:**
- Use `project_key` (NOT `project`)
- Use `issue_type` (NOT `issuetype`)
- Labels go in `additional_fields: {"labels": [...]}`, NOT as a top-level parameter
- Reporter auto-assigns — do not pass it

### 5. Serena

| Field | Value |
|-------|-------|
| **Package** | `serena-mcp-server` (via `uvx` from git) |
| **Command** | `uvx --from git+https://github.com/oraios/serena serena-mcp-server` |
| **Purpose** | Semantic/symbolic code navigation and editing |
| **Auth** | None (local tool) |

**Key gotchas:**
- **MUST call `activate_project` first** with the project path before using any other Serena tools.
- Requires `DOTNET_ROOT` and `PATH` env vars for .NET project support.
- Full usage guide: see `reference/serena.md`.
- Use for code projects only — not useful for pure authoring sessions (context waste).

---

## Additional Servers (Not Included by Default)

These can be added to `.mcp.json` if needed:

| Server | Package | Purpose | Auth |
|--------|---------|---------|------|
| **Slack** | `@modelcontextprotocol/server-slack` | Channels, messages, threads | Bot token (xoxb-) |
| **Linear** | `mcp-linear` | Issues, projects, cycles | API key |
| **Postgres** | `@modelcontextprotocol/server-postgres` | Direct database queries | Connection string |
| **Filesystem** | `@modelcontextprotocol/server-filesystem` | Controlled file access | Path allowlist |
| **Brave Search** | `@modelcontextprotocol/server-brave-search` | Web search | API key |
| **Fetch** | `@modelcontextprotocol/server-fetch` | HTTP requests | None |
| **Memory** | `@modelcontextprotocol/server-memory` | Persistent knowledge graph | None |
| **Notion** | Community servers | Pages, databases | Integration token |
| **PST Search** | Custom Python server | Email archive search | None (local data) |

---

## MCP Configuration Architecture

**Getting this wrong breaks MCP server discovery.** Three separate files, each with a distinct role:

| What | Where | NOT Here |
|------|-------|----------|
| Server definitions (command, args, env) | `.mcp.json` files | ~~settings.json~~ |
| Server enablement flags | `settings.local.json` | ~~.claude.json~~ |
| Env vars, permissions, plugins | `settings.json` | |

### File format requirements

- **`.mcp.json`** must have the `mcpServers` wrapper:
  ```json
  { "mcpServers": { "server-name": { "command": "...", "args": [...], "env": {...} } } }
  ```

- **`settings.local.json`** needs BOTH flags:
  - `enableAllProjectMcpServers: true`
  - `enabledMcpjsonServers: [...]` (list of server names)

### Adding a new server

1. Add the server definition to `~/.claude/.mcp.json` under `mcpServers`
2. Add the server name to `enabledMcpjsonServers` in `settings.local.json`
3. Restart Claude Code (MCP servers cache env vars at startup)

### Project-level overrides

Claude Code walks up from the project directory looking for `.mcp.json`. A project-level copy takes precedence over `~/.claude/.mcp.json`.

**If MCP tools aren't available in a session**, the servers may have failed to start. Check by restarting Claude Code or reviewing startup output.

---

## Troubleshooting: GitHub "Not Found" on Private Repos

**Most likely cause: wrong env var name.** The `@modelcontextprotocol/server-github` reads `GITHUB_PERSONAL_ACCESS_TOKEN`, NOT `GITHUB_TOKEN`. With the wrong name, the server runs unauthenticated — public repos work, private repos return 404.

**Quick diagnostic:**

1. Try listing issues on a **public** repo. If public works but private fails:
   - **Wrong env var name in `.mcp.json`.** Fix: change `"GITHUB_TOKEN"` to `"GITHUB_PERSONAL_ACCESS_TOKEN"`, then restart.

2. **Check for project-level `.mcp.json` override:**
   ```bash
   ls <project>/.mcp.json   # if it exists, verify the env var name
   ```

3. If public repos also fail: server process issue. Check the token and restart.

---

## Troubleshooting: Token & Auth Issues

**MCP servers cache env vars at startup.** After token changes in `.mcp.json`, you MUST restart Claude Code.

**If restarting doesn't help**, test the token directly:

```bash
TOKEN=$(python3 -c "import json; d=json.load(open('$HOME/.claude/.mcp.json')); print(d['mcpServers']['github']['env'].get('GITHUB_PERSONAL_ACCESS_TOKEN', 'MISSING'))")
curl -sI -H "Authorization: token $TOKEN" https://api.github.com/user | grep x-oauth-scopes
```

- Scopes should include `repo`. If missing, regenerate the PAT.
- If curl works but MCP doesn't: check the env var name (see above).

---

## General Notes

- **Restart after any `.mcp.json` change.** MCP servers cache env vars at startup.
- **Do NOT embed tokens in documentation.** Reference `.mcp.json` for all credentials.
- **MCP servers are currently global**, not per-project. Roster changes require editing `.mcp.json` and restarting.
- **Irrelevant servers waste context** — their tool descriptions are loaded even when unused. Consider which servers are relevant per session type.
