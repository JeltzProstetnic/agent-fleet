# Setup Scripts (Internal)

These are internal setup scripts used by `setup.sh` at the repo root. **You should not need to run them directly.**

## Canonical entry point

```bash
cd ~/cfg-agent-fleet && bash setup.sh
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
