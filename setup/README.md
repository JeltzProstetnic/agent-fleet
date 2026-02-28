# Setup Scripts

> **Note:** Most users only need `setup.sh` at the repo root. The scripts in this
> directory install Claude Code itself (via cc-mirror) and are for advanced users
> who want a custom Claude Code installation. Skip this directory unless you know
> you need it.

## Two entry points — which to use

| Entry point | What it does | When to use |
|-------------|-------------|-------------|
| **`setup.sh`** (repo root) | Profile, infrastructure, symlinks, MCP config | Fresh install on a new machine, or re-linking after a git clone |
| **`setup/install.sh`** | System deps, Node.js, cc-mirror, VoltAgent, launcher patches | Full system setup (installs packages), or upgrading Claude Code components |

**For a brand-new machine:** Run `setup/install.sh` first (installs dependencies), then `setup.sh` (configures everything). Or just run `setup.sh` — it works without `install.sh` if deps are already present.

**For an existing machine:** Usually `setup.sh` is enough (re-links config, updates MCP). Only run `install.sh` if you need to update system dependencies or the Claude Code installation.

## Canonical entry point

```bash
cd ~/agent-fleet && bash setup.sh
```

## What's in here

| Script | Purpose |
|--------|---------|
| `install-base.sh` | Phase 1: system deps, Node.js, npm, cc-mirror, mclaude variant |
| `configure-claude.sh` | Phase 2: VoltAgent, MCP servers, launcher patches, CLAUDE.md, WSL settings |
| `install.sh` | Orchestrator that runs Phase 1 + Phase 2 in sequence |
| `lib.sh` | Shared utility functions (logging, backup, prompts) |
| `scripts/` | Helper scripts deployed to `~/.cc-mirror/mclaude/scripts/` |
| `config/` | Template configs (settings.json, mcp.json.template, CLAUDE.md) |

## When to use these directly

- **Re-running only Phase 2** (e.g., after changing MCP credentials): `bash setup/configure-claude.sh --reconfigure-mcp`
- **Dry run preview**: `bash setup/install.sh --dry-run`
- **Rollback**: `bash setup/install.sh --rollback`

For fresh installs, always use `setup.sh` at the repo root.
