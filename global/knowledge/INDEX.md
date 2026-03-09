# Operational Knowledge — Index

Conditionally loaded files containing operational knowledge for specific tools and skills. Not loaded at startup — only when triggered by context (see global CLAUDE.md conditional loading section).

## How It Works

1. Files here are reference material for specific tools/skills
2. Load them only when a task requires that tool or skill
3. Update during sessions when you discover workarounds, bugs, or operational insights
4. If a gotcha is discovered, add it to the relevant file

## Files

| File | Trigger | Content |
|------|---------|---------|
| `mcp-deployment.md` | Adding new MCP server or debugging MCP server config | Pre-deployment checklist, port conflicts, onboarding suppression, per-server notes |
| `plan-mode-issues.md` | Plan mode hangs, freezes, or unresponsive UI | Root cause (MCP deadlock), workarounds, diagnostic data |
| `claude-code-permissions.md` | Permission prompts, settings.local.json issues | Override problem, fix procedure, prevention |
| `learn-protocol.md` | `lrn`/`learn` command issued | Self-audit protocol: 3 parallel subagents for rule compliance, knowledge capture, and improvement finding |
| `hook-behavior.md` | Hook debugging, platform-specific hook issues | UserPromptSubmit gaps, PreToolUse subagent support, urandom quirks |
| `dev-browser-ops.md` | Using dev-browser skill or browser automation | Startup, Chromium drift fix, session persistence |
| `age-encryption.md` | Encryption tasks involving age/pyrage | age CLI TTY limitation, pyrage alternative, passphrase handling |
| `fleet-capabilities.md` | Self-awareness, plugin recommendation, agent roster gaps | Core features catalog, agent capabilities, plugin mapping, recommendation protocol |
| `audit-protocol.md` | Audit, self-audit, meta-audit | 3 lines of defense, 8-step workflow, system invariants, audit log format |

## Adding New Knowledge Files

1. Create `<tool-or-skill>.md` in this directory
2. Add a conditional loading entry in `global/CLAUDE.md` (see "Conditional loading" section)
3. Update this INDEX
4. Format: filename is lowercase, hyphens for spaces (e.g., `dev-browser-ops.md`)
5. Propagate to template if generic (strip personal details)
