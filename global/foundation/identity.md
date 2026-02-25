# Claude Code Identity & Configuration

## Config Repo — Source of Truth

All global configuration, rules, and the project registry are tracked in `~/claude-config/` (Git-tracked, pushed to GitHub). This file and all rule modules are managed from that repo.

- **Registry**: `~/claude-config/registry.md` — lists all projects, their locations, platforms, and roster snapshots
- **Auto-sync**: A `SessionEnd` hook at `~/.claude/hooks/config-auto-sync.sh` automatically commits and pushes config changes when any session ends. No manual sync needed.
- **Manual sync** (if needed): `bash ~/claude-config/sync.sh status|deploy|collect|setup`
- **When creating a new project**: add it to `~/claude-config/registry.md`
- **Cross-machine**: this repo should be cloned on every machine. The registry tracks which projects exist on which machines.

## Key Paths

| Resource | Location |
|----------|----------|
| Global CLAUDE.md | `~/.claude/CLAUDE.md` |
| Foundation modules | `~/.claude/foundation/` |
| Reference docs | `~/.claude/reference/` |
| Domain knowledge | `~/.claude/domains/` |
| MCP server definitions | `~/.mcp.json` |
| Machine catalog | `~/claude-config/machine-catalog.md` |

For installed tools, software versions, and machine-specific notes, see `~/claude-config/machine-catalog.md`.

## MCP Servers Configured

List your configured MCP servers here. Example format:

| Server | Package / binary | Purpose |
|--------|-----------------|---------|
| **GitHub** | `@modelcontextprotocol/server-github` | GitHub operations (repos, issues, PRs) |
| **Serena** | `serena` | Semantic code navigation and editing |

For MCP troubleshooting, configuration architecture, and operational details, see `~/.claude/reference/mcp-catalog.md`.

## When User Asks About Configuration

- MCP server definitions: `~/.mcp.json`
- Behavioral guidance: `~/.claude/CLAUDE.md`
- MCP operational catalog (troubleshooting, architecture): `~/.claude/reference/mcp-catalog.md`
- Serena usage guide: `~/.claude/reference/serena.md`
- Tool permissions and subagent support: `~/.claude/reference/permissions.md`
