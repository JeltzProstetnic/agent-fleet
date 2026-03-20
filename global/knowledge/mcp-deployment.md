# MCP Server Deployment — Lessons & Patterns

**MCP config changes require restart.** Changes to `.mcp.json` are invisible to the current session. After fixes: verify file, tell user to restart, flag verification pending. Never mark "done" without a live tool test in a new session.

## Pre-deployment checklist for new MCP servers

When adding a new MCP server to the fleet, verify these BEFORE deploying to machines:

### 1. Config file defaults
- **Does the server create config files on first run?** (e.g., Serena → `~/.serena/serena_config.yml`)
- **Are any defaults problematic?** (GUI popups, browser opens, telemetry, auto-updates)
- **Pre-deploy the config** from bootstrap/configure scripts with sane defaults
- Example: Serena's `web_dashboard_open_on_launch: true` → browser opens every launch

### 2. Port conflicts
- **Does the server bind to a port?** Check for HTTP servers, OAuth callbacks, WebSocket endpoints
- **Does it have sub-processes that also bind ports?** (e.g., workspace-mcp: main server + OAuth callback both use 8000)
- **Always set ports explicitly** via env vars or args — never rely on defaults
- Example: `WORKSPACE_MCP_PORT=8001` in `.mcp.json` env

### 3. Auth flow requirements
- **Does it need OAuth?** If so, which port does the callback server use?
- **Does it need a browser?** Set `BROWSER` env var for non-standard environments (e.g., `flatpak run com.google.Chrome` on SteamOS)
- **Where are tokens cached?** Know the path so you can verify/reset auth state

### 4. Onboarding/nag suppression
- **Does the server have an onboarding flow?** (e.g., Serena's `check_onboarding_performed`)
- **What state does it check?** (memory files, config flags, marker files)
- **Pre-populate the required state** to suppress nag on every session start
- Example: Serena checks for project memories — write them once during activation

### 5. Platform compatibility
- **Does it require specific binaries?** (Node.js, Python, dotnet, etc.)
- **Does it work on all target platforms?** (SteamOS, WSL, VPS, Fedora)
- **PATH requirements**: always set explicit PATH in `.mcp.json` env — don't rely on shell PATH inheritance
- **NVM node path (non-standard installs)**: Even when `npx` is called via its full NVM path (e.g., `/home/user/.nvm/versions/node/v22.x.x/bin/npx`), the spawned process may call `node` via PATH. If `node` isn't in the system PATH (SteamOS, some server distros), this fails with `/usr/bin/env: 'node': No such file or directory`. **Fix**: add the NVM bin directory to the PATH env var in `.mcp.json`, BEFORE the other entries: `"/home/user/.nvm/versions/node/v22.x.x/bin:/home/user/.local/bin:..."`. This affects ALL node-based MCP servers.

### 6. uvx version compatibility (Python-based MCP servers)

**Problem:** `uvx -y <package>` syntax varies by uv version:
- **uv 0.9.x** (Fedora 42, older installs): `-y` flag doesn't exist → "unexpected argument '-y' found" error
- **uv 0.10+** (npm installs, recent pipx): `-y` flag works (auto-confirm)

**Impact:** MCP configs using `uvx -y` fail silently on older uv versions. Server appears "not configured" even when the config is present.

**Mitigations:**
- **Use version-agnostic syntax:** Just `uvx <package>` without `-y`. The interactive prompt concern doesn't apply in MCP context (no terminal).
- **Document uv version per machine** in machine files
- **vault-manage.sh deploy:** Should check uv version and warn if args may fail

**Affected servers:** Any Python-based MCP server via uvx (mcp-atlassian, serena if installed via uvx, diagram, etc.)

## enabledMcpjsonServers — the silent killer

When adding a new MCP server to `~/.mcp.json`, you MUST also add its name to `enabledMcpjsonServers` in EVERY project's `settings.local.json`. This list acts as a whitelist — unlisted servers silently fail to connect, even if perfectly configured.

**The mclaude launcher should handle this automatically** (patching settings.local.json at startup). If it's not doing so, the launcher's patching logic needs fixing. When manually deploying, always update:
1. `~/.mcp.json` — add server definition
2. Every `<project>/.claude/settings.local.json` — add server name to `enabledMcpjsonServers`

**Deployment script (`configure-claude.sh`) MUST:**
- Set `enabledMcpjsonServers` to include ALL servers defined in `.mcp.json`
- Set `enableAllProjectMcpServers: true`
- NEVER include a `permissions` block (auto-clean hook will remove it anyway)

## Auto-clean: permissions contamination (config-check.sh Check 10)

Claude Code's "Always allow" button writes permission entries to `settings.local.json`. These REPLACE global permissions, causing prompt storms. The SessionStart hook `config-check.sh` Check 10 auto-removes any `permissions` block from all project `settings.local.json` files. See `~/.claude/knowledge/claude-code-permissions.md` for full details.

## Plugin marketplace cleanup (clean-marketplace-plugins.sh)

The cleanup script handles TWO problems:
1. **External plugin directories**: Marketplace auto-installs third-party plugins (asana, stripe, etc.) that duplicate our MCP servers or are useless. Script removes all except `KEEP_PLUGINS` allowlist.
2. **Stale enabledPlugins entries**: `settings.json` can accumulate references to plugins from non-existent marketplaces (e.g., community marketplace entries). These cause "N plugins failed to install" errors at startup. Script removes entries from any marketplace other than `claude-plugins-official`.

## npx-based MCP Servers — Fragility Pattern

npx-based servers (`npx -y <package>`) have a recurring failure mode:

1. **Cache refresh loses patches.** Any local patch (sed replacements in `~/.npm/_npx/`) is wiped when npx refreshes the cache (version change, cache corruption, Node.js upgrade).
2. **Cache refresh can break transitive deps.** Heavy dependencies like `jsdom` may not resolve correctly after a fresh fetch.
3. **Version drift.** Without pinning, `npx -y <package>` pulls latest — which may rename env vars, change APIs, or introduce new bugs.

**MCP health checks guidance:** Per-session health checks are too expensive in tokens when servers are stable (which is most of the time). If implemented, MUST be date-gated (once per day max, like upstream version checks), not per-session. Breakages are rare enough that reactive detection + documented recovery playbooks are more cost-effective than proactive probing.

**Mitigations:**
- **Always pin versions** in `.mcp.json` args: `some-server@2.1.0`, not `some-server`
- **Document patches** in `~/.claude/knowledge/<server>.md` with exact sed commands and verification steps
- **After any Node.js update or npx cache issue:** re-apply all patches, test with live tool calls
- **Long-term for patched servers:** consider local install (`npm install <package>@<version>` in a dedicated dir) instead of npx — immune to cache refresh

## Known server-specific notes

### Serena (code navigation)
- Config: `~/.serena/serena_config.yml` — pre-deployed by configure-claude.sh
- Key setting: `web_dashboard_open_on_launch: false` (in config file)
- **CLI override:** `--open-web-dashboard false` in MCP server args (takes precedence over config)
- Onboarding: write memories for each project on first activation
- Context: `--context claude-code` (optimized tool set for Claude Code)

### workspace-mcp (Google Workspace / Gmail)
- Port: set `WORKSPACE_MCP_PORT=8001` (default 8000 conflicts with OAuth callback)
- Browser: set `BROWSER` env var for non-standard browsers
- Auth cache: `~/.google_workspace_mcp/credentials/`
- Scope: `--tools gmail` limits to Gmail only (faster startup, smaller tool set)
- **CRITICAL env var names**: `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET` (NOT `GOOGLE_CLIENT_ID`). workspace-mcp >=1.13 ONLY reads the `GOOGLE_OAUTH_*` variants. Using the wrong names causes silent failure with misleading "client_secret.json not found" errors.
- **Post-deploy verification**: ALWAYS test with an actual MCP tool call (e.g., `search_gmail_messages`) after deploying. Never claim "next session it'll work" without testing.

### GitHub MCP
- Auth: `GITHUB_PERSONAL_ACCESS_TOKEN` env var
- Multi-org: separate server entries for different PATs (e.g., `github` vs `github_work`)
- **DEPRECATED:** `@modelcontextprotocol/server-github` (npm) still works but is no longer maintained
- **Replacement:** `github/github-mcp-server` (Go-based) — requires Docker or Go. Migration pending.
- The old npx server emits deprecation warnings but functions correctly (26 tools)

### Twitter MCP
- Auth: 4 env vars (API_KEY, API_SECRET, ACCESS_TOKEN, ACCESS_SECRET)
- Known bug: `search_tweets` returns 402 (API tier limitation)

### Playwright MCP
- No config files, no auth
- Needs browser binary available

### Diagram (mcp-mermaid-image-gen)
- Requires `mmdc` globally installed (`npm install -g @mermaid-js/mermaid-cli`)
- Python-based via uvx
