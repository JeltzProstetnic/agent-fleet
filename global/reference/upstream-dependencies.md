# Upstream Dependency Tracker

**Load when:** Daily session start check (see CLAUDE.md), or when investigating updates.

This file tracks all upstream dependencies — things we don't control that can change under us. Every dependency has a check procedure and impact assessment before updating.

## Critical Path Dependencies

### 1. Claude Code (`@anthropic-ai/claude-code`)
| Field | Value |
|-------|-------|
| **Source** | npm: `@anthropic-ai/claude-code` |
| **GitHub** | `anthropics/claude-code` |
| **Installed** | Check: find `package.json` in your Claude Code install dir and read the `version` field |
| **Latest** | Check: `npm view @anthropic-ai/claude-code version` |
| **Auto-updates** | Depends on your setup (`DISABLE_AUTOUPDATER=1` in settings.json to prevent) |
| **Update method** | Manual: `npm install @anthropic-ai/claude-code@<version>` in your install directory |
| **Impact** | HIGH — changes tool schemas, system prompts, hook behavior, permissions model, statusline API |

**Before updating:**
1. Read changelog/release notes on GitHub
2. Check for breaking changes in: hook API, settings.json schema, MCP protocol, statusline JSON format, permissions syntax
3. Check if any system-prompt patches still apply (hash comparison)
4. Test on one machine first (prefer lowest-risk machine)
5. If statusline JSON format changes, update `setup/config/statusline.sh`
6. If permissions syntax changes, update `setup/config/settings.json` template

### 2. VoltAgent Plugins
| Field | Value |
|-------|-------|
| **Source** | GitHub: `VoltAgent/awesome-claude-code-subagents` |
| **Auto-updates** | NO (cached at install time) |
| **Impact** | MEDIUM — defines subagent types (Task tool), their tool access, and system prompts |

**Before updating:**
1. Check `VoltAgent/awesome-claude-code-subagents` releases/commits for changes
2. Compare new agent definitions against current ones (tool lists, prompts)
3. Verify no agents were removed that you depend on
4. Check if new agents require MCP servers you don't have
5. Test subagent spawning after update

### 3. Anthropic Official Plugins (`claude-plugins-official`)
| Field | Value |
|-------|-------|
| **Source** | GitHub: `anthropics/claude-plugins-official` |
| **Impact** | LOW — external plugin definitions, most not enabled |

## MCP Server Dependencies

All MCP servers run via `npx -y` which fetches the latest version on each invocation. This means they update silently.

### Server Version Check Command
```bash
for pkg in "@modelcontextprotocol/server-github" "mcp-atlassian" "@playwright/mcp" "@modelcontextprotocol/server-postgres" "@modelcontextprotocol/server-memory"; do
  echo "$pkg: $(npm view "$pkg" version 2>/dev/null || echo '?')"
done
```

### Individual Servers

| Server | Package | Deprecation | Notes |
|--------|---------|-------------|-------|
| GitHub | `@modelcontextprotocol/server-github` | **DEPRECATED** — replacement: `github/github-mcp-server` (Go) | Still works. Migration needs Go or Docker. |
| Atlassian | `mcp-atlassian` | Active | Known bug: null issues array. Patch may be lost on npx cache refresh. |
| Playwright | `@playwright/mcp` | Active | Uses **alpha** playwright builds. Watch for breaking changes. |
| Postgres | `@modelcontextprotocol/server-postgres` | **DEPRECATED** | Works fine. Low risk. |
| Memory | `@modelcontextprotocol/server-memory` | Active | Anthropic-maintained. |

**MCP update risk:** Since `npx -y` always fetches latest, a breaking change in any MCP server takes effect immediately on next restart. No rollback without pinning versions.

**Mitigation:** Pin critical servers by specifying `@version` in `.mcp.json` args. See `knowledge/mcp-deployment.md` for the npx fragility pattern.

## Monitored Upstream Bugs

| Bug | Upstream Issue | Impact | Status | Last Checked |
|-----|---------------|--------|--------|-------------|
| Plan mode hang (extended thinking) | `anthropics/claude-code#26224`, `#29712` | EnterPlanMode unusable, workaround: Plan subagent | Open | — |

## System-Level Dependencies

Versions and update methods vary per machine. Check your machine file (`~/.claude/machines/<machine>.md`) for specifics.

| Tool | Purpose | Common Update Methods |
|------|---------|----------------------|
| Node.js | Claude Code runtime | `dnf update nodejs`, `nvm install`, `apt update nodejs` |
| Python | MCP servers, scripts | `dnf update python3`, `apt update python3` |
| uvx | MCP server runner | `pipx upgrade uv` or `pip install --upgrade uv` |
| pandoc | Document conversion | Package manager (`dnf`, `apt`) |
| weasyprint | PDF generation | `pipx upgrade weasyprint` |
| git | Version control | Package manager |
| jq | JSON processing | Package manager |

## Daily Check Procedure

Run at first session start each day (any machine, any project):

1. **Claude Code version:** `npm view @anthropic-ai/claude-code version` vs installed
2. **Plan mode bug:** Check upstream issues for resolution
3. **VoltAgent plugins:** Check for new commits (weekly, not daily)
4. **MCP deprecations:** Note any new deprecation warnings in startup output

Report findings to user. **NEVER suggest updating without first investigating the changelog and assessing impact on your system.** The user decides when to update.
