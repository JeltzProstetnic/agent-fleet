# WSL Claude Code Complete Setup

> **Note:** This repository has been absorbed into the `claude-config` global configuration repo.
> Location: `~/claude-config/setup/`
> Status: Reference copy maintained for reusability across machines

Complete, reproducible setup for running Claude Code on WSL with cc-mirror, VoltAgent subagents, MCP servers, and happy-coder mobile access.

## Installation

For the full installation guide and documentation, see the original README at:
**https://github.com/__GITHUB_USERNAME__/wsl-claude-setup/blob/main/README.md**

## Quick Start (from claude-config)

```bash
# Step 1: Install system dependencies (may prompt for sudo)
cd ~/claude-config/setup && bash install-base.sh

# Step 2: Configure Claude Code (prompts for tokens)
bash configure-claude.sh
```

## Repository Status

This setup has been integrated into the unified `~/claude-config/` repository:

- **Original standalone repo**: `~/wsl-claude-setup/` (archived)
- **New location**: `~/claude-config/setup/` (active)
- **Purpose**: Portable setup scripts deployable to any WSL machine

All future updates should be made to `~/claude-config/setup/` and synced via the config repo's sync tooling.
