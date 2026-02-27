# Getting Started from Zero

You have a computer. You want Claude Code to remember things, work across projects, and sync between machines. Here's how to get there.

## Prerequisites

You need:

1. **A terminal** — Linux, macOS, or WSL on Windows
2. **git** — `sudo apt install git` (Ubuntu/WSL) or `brew install git` (macOS)
3. **Node.js 18+** — `sudo apt install nodejs npm` (Ubuntu/WSL) or `brew install node` (macOS). Needed for MCP servers.
4. **Claude Code installed** — See [claude.ai/claude-code](https://claude.ai/claude-code) for installation

## Step 1: Clone and run setup

```bash
git clone https://github.com/YOUR_USERNAME/cfg-agent-fleet ~/cfg-agent-fleet
cd ~/cfg-agent-fleet
bash setup.sh
```

The script walks you through:

| Prompt | What to enter |
|--------|---------------|
| Your name | Your full name |
| Your role | What you do (e.g., "Software engineer") |
| Background | One-line description of yourself |
| Communication style | How you prefer responses (e.g., "Direct and technical") |
| Machine ID | A label for this computer (default: hostname) |

## Step 2: Set up MCP servers (optional)

The script asks about each one. Skip any you don't need — you can set them up later.

| Server | What it does | What you need |
|--------|-------------|---------------|
| GitHub | Manage repos, issues, PRs | Personal Access Token ([create one](https://github.com/settings/tokens)) |
| Google Workspace | Gmail, Docs, Calendar, Drive | OAuth Client ID ([create one](https://console.cloud.google.com/apis/credentials)) |
| Twitter/X | Post tweets | API keys ([developer.x.com](https://developer.x.com)) |
| Jira | Issues, sprints, Confluence | API token ([create one](https://id.atlassian.com/manage-profile/security/api-tokens)) |
| PostgreSQL | Database queries | Connection URL |

These are always included (no credentials needed): **Serena** (code navigation), **Playwright** (browser automation), **Memory** (knowledge graph), **Diagram** (Mermaid diagrams).

## Step 3: Launch Claude

After setup completes:

```bash
claude    # or mclaude if using cc-mirror
```

Claude will:
- Detect your configuration
- Load your user profile
- Start tracking session state automatically
- Have access to all the MCP servers you configured

## What just happened?

The setup script created this structure:

```
~/.claude/
  CLAUDE.md     -> ~/cfg-agent-fleet/global/CLAUDE.md     (symlink)
  foundation/   -> ~/cfg-agent-fleet/global/foundation/   (symlink)
  domains/      -> ~/cfg-agent-fleet/global/domains/       (symlink)
  reference/    -> ~/cfg-agent-fleet/global/reference/     (symlink)
  knowledge/    -> ~/cfg-agent-fleet/global/knowledge/     (symlink)
  machines/     -> ~/cfg-agent-fleet/global/machines/      (symlink)
  hooks/        (copied from global/hooks/)

~/.mcp.json     (generated with your MCP server credentials)
~/CLAUDE.local.md  (points to your machine file)
```

Your config lives in `~/cfg-agent-fleet/` (a git repo). Edit there, and changes propagate to `~/.claude/` via symlinks.

## Adding a second machine

On the new machine:

```bash
git clone YOUR_REPO_URL ~/cfg-agent-fleet
cd ~/cfg-agent-fleet
bash setup.sh
```

Same setup, same config. Session state and knowledge sync via git (push from one machine, pull on the next).

## Adding a project

When Claude is running in any project directory, it automatically picks up the global config. To add project-specific rules:

1. Create `<project>/.claude/CLAUDE.md` with project-specific instructions
2. Add the project to `~/cfg-agent-fleet/registry.md`

The example at `projects/_example/rules/CLAUDE.md` shows the format.

## Customizing domains

Domains are knowledge modules that load per-project. The included ones:

- **Software Development** — TDD, code review conventions
- **Publications** — Markdown to PDF pipeline
- **Engagement** — Community interaction protocols
- **IT Infrastructure** — Server and deployment management

To add your own: copy `global/domains/_template/`, edit, and reference it from your project's `CLAUDE.md`.

## Troubleshooting

**Claude doesn't see MCP servers:** Restart Claude. MCP servers cache credentials at startup.

**Private GitHub repos return 404:** The env var must be `GITHUB_PERSONAL_ACCESS_TOKEN` (not `GITHUB_TOKEN`). Check `~/.claude/.mcp.json`.

**Session state not persisting:** Make sure you're running Claude from a project directory that has `session-context.md`, or from `~/cfg-agent-fleet/` itself.

**Need to change MCP credentials:** Edit `~/.mcp.json` directly, or re-run `bash ~/cfg-agent-fleet/setup.sh` (it backs up existing files before overwriting). Restart Claude Code after changes.
