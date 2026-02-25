# MCP Server Catalog — Operational Reference

**Canonical MCP config:** `~/.cc-mirror/mclaude/config/.mcp.json`
**Global copy (auto-synced by launcher):** `~/.mcp.json`

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
- Project-level `.mcp.json` files override the global config. Claude Code walks up from the project dir looking for `.mcp.json`. The mclaude launcher syncs to `~/.mcp.json` but does NOT update project-level copies. Always check `<project>/.mcp.json` if private repos 404.
- The `gh` CLI is NOT covered by this MCP server. Use MCP GitHub tools or `curl` for GitHub API calls.
- Token scope must include `repo`. Test with: `curl -sI -H "Authorization: token $TOKEN" https://api.github.com/user | grep x-oauth-scopes`

### 2. Google Workspace

| Field | Value |
|-------|-------|
| **Package** | `workspace-mcp` (via `uvx`) |
| **Command** | `uvx workspace-mcp` |
| **Purpose** | Gmail, Google Docs, Sheets, Calendar, Drive, Contacts, Tasks, Forms, Presentations |
| **Auth** | OAuth (client ID + secret in `.mcp.json`) |

**Key gotchas:**
- **CRITICAL for Gmail:** ALWAYS use `__YOUR_EMAIL__` (working OAuth). Do NOT use `__YOUR_EMAIL__` (broken auth). Mail forwards between the two accounts.
- The `USER_GOOGLE_EMAIL` field in `.mcp.json` is set to `__YOUR_EMAIL__` — this may be wrong for Gmail operations. Override with the correct email when making Gmail calls.
- OAuth tokens may expire. If auth fails, may need to re-authorize via browser.

### 3. Twitter

| Field | Value |
|-------|-------|
| **Package** | `@enescinar/twitter-mcp` |
| **Command** | `npx -y @enescinar/twitter-mcp` |
| **Purpose** | Post tweets, search tweets |
| **Auth** | API key + secret, access token + secret (in `.mcp.json`) |

**Key gotchas:**
- **NEVER post tweets autonomously.** Always get explicit user approval before calling `post_tweet`.
- Available tools: `post_tweet`, `search_tweets`.
- Rate limits apply per Twitter API tier.

### 4. Serena

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

### 5. PST Search

| Field | Value |
|-------|-------|
| **Package** | Custom Python server |
| **Command** | `/home/__USERNAME__/mails/.venv/bin/python /home/__USERNAME__/mails/src/pst_search/server.py` |
| **Working dir** | `/home/__USERNAME__/mails` |
| **Purpose** | Email archive search (PST file indexing and querying) |
| **Auth** | None (local data) |

**Key gotchas:**
- Runs from the `~/mails/` directory with its own Python venv.
- Available tools: `search_emails`, `search_emails_fts`, `get_email`, `get_thread`, `summarize_thread`, `filter_emails`, `find_unanswered_emails`, `enrich_emails`, `list_folders`, `get_stats`, `get_enrichment_status`, `rebuild_index`.
- Local data only — no external API calls.

---

## Inactive Servers (Not in Current `.mcp.json`)

### 6. Jira (INACTIVE)

| Field | Value |
|-------|-------|
| **Package** | `mcp-atlassian` |
| **Purpose** | Jira/Atlassian operations: issues, projects, boards |
| **Status** | Documented in old CLAUDE.md but NOT present in current `.mcp.json` |

**Parameter quirks (if re-enabled):**
- Use `project_key` (NOT `project`)
- Use `issue_type` (NOT `issuetype`)
- Labels go in `additional_fields: {"labels": [...]}`, NOT as a top-level parameter
- Reporter auto-assigns — do not pass it

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

1. Try `list_issues` on a **public** repo (e.g. `__GITHUB_USERNAME__/Toolbox`). If public works but private fails:
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
- **MCP servers are currently global**, not per-project. Roster changes require editing `.mcp.json` and restarting. Future improvement: per-project `.mcp.json`.
- **Irrelevant servers waste context** — their tool descriptions are loaded even when unused. Consider which servers are relevant per session type.
