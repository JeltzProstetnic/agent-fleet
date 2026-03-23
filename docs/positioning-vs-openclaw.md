# Agent Fleet vs OpenClaw — Positioning

## TL;DR

They're different categories. OpenClaw is a **personal AI assistant** (messaging bridge + background daemon). Agent Fleet is **AI operations infrastructure** (multi-machine fleet management for terminal-based coding agents). They share a "markdown as configuration" philosophy but solve different problems for different users.

## OpenClaw

**Creator:** Peter Steinberger (Austrian, PSPDFKit founder, now at OpenAI).
**History:** Clawdbot (Nov 2025) → Moltbot (Jan 2026, Anthropic trademark issue) → OpenClaw (Jan 30, 2026).
**Stars:** ~68k+. Wikipedia page. Foundation-owned since Feb 2026.

**What it does:**
- Connects 20+ messaging platforms (WhatsApp, Telegram, Slack, Discord, Signal, iMessage) to LLMs
- Background heartbeat daemon executes tasks autonomously without prompting
- Skills marketplace (Smithery) for community extensions
- Web browsing, shell commands, file management, smart home, calendar, email
- Plain-text workspace: `SOUL.md` (persona), `AGENTS.md` (SOP), `USER.md` (identity), `MEMORY.md` (long-term), daily memory files

**Target:** "Personal AI assistant for everyone." Consumer-friendly, one agent, broad capabilities.

## Agent Fleet

**What it does:**
- Multi-machine configuration management for Claude Code (or any terminal AI agent)
- Cross-project orchestration with inbox, registry, boundary rules
- 4-layer session persistence (next-session → context → history → archive)
- Conditional knowledge loading (token-efficient, only load what's needed)
- Hook pipelines (SessionStart, SessionEnd, PreToolUse, PostToolUse, UserPromptSubmit)
- Encrypted vault with per-machine credential deployment
- Config propagation via template system (canonical source → child projects)
- Multi-persona system with context-based switching
- 570+ tests, TDD-enforced

**Target:** "Professional multi-machine AI operations infrastructure." Deep, specialized, for power users running AI coding agents across multiple projects and machines.

## Feature Comparison

| Capability | OpenClaw | Agent Fleet |
|-----------|----------|-------------|
| **Primary interface** | Messaging apps (WhatsApp, Telegram, etc.) | Terminal (Claude Code, potentially OpenCode) |
| **Autonomous execution** | Yes (heartbeat daemon) | No (requires active session) |
| **Multi-machine sync** | No (single instance) | Yes (git-based, 6+ machines) |
| **Multi-project** | No (one workspace) | Yes (registry, cross-project inbox, boundary rules) |
| **Session persistence** | Daily files + MEMORY.md | 4-layer system (context → history → log → decisions) |
| **Knowledge loading** | All files loaded every time | Conditional (trigger-based, token-efficient) |
| **Hook system** | Heartbeat daemon | 5 hook types (SessionStart/End, Pre/PostToolUse, UserPromptSubmit) |
| **Credential management** | Platform-specific | Encrypted vault with `deploy_to` targets |
| **Config propagation** | Manual | `sync.sh template-push` with sanitization + leak detection |
| **Persona system** | `SOUL.md` (single) | Multi-persona with auto-switching rules + per-machine overrides |
| **Skills/extensions** | Smithery marketplace | Skill collections (getsentry, obra, trailofbits) |
| **Setup complexity** | One folder, few files | Multi-repo system, steep onboarding (but guided) |
| **Test suite** | Unknown | 570+ tests across 33 suites |
| **Backend lock-in** | Any LLM (OpenAI, Claude, etc.) | Currently Claude Code (OpenCode evaluation in backlog) |

## Workspace File Mapping

The philosophical overlap is in "plain markdown as configuration":

| OpenClaw | Agent Fleet | Notes |
|----------|-------------|-------|
| `SOUL.md` | `foundation/personas.md` + persona rules | Agent Fleet has multi-persona with auto-switching |
| `AGENTS.md` | `CLAUDE.md` (global prompt) | Agent Fleet is much larger — layered dispatch system |
| `USER.md` | `foundation/user-profile.md` | Similar purpose, similar format |
| `MEMORY.md` | No equivalent (by design) | Agent Fleet routes to proper knowledge files, not a catch-all |
| `memory/YYYY-MM-DD.md` | `session-context.md` + `session-history.md` | Agent Fleet has structured rotation and archival |
| `HEARTBEAT.md` | AFD daemon + hooks (partial) | Agent Fleet doesn't do autonomous execution |

## Other Claude Code Config Projects

| Project | Stars | What it is | Overlap with Agent Fleet |
|---------|-------|-----------|-------------------------|
| **trailofbits/claude-code-config** | ~5k | Security-focused CC defaults | Settings template only — no sync, no multi-machine |
| **feiskyer/claude-code-settings** | ~2k | Curated settings + skills | Config collection — no lifecycle management |
| **Matt-Dionis/claude-code-configs** | ~500 | Shareable CC configs | Sharing mechanism — no session persistence |
| **Chezmoi + CC** | (pattern) | Dotfiles sync with age encryption | Sync only — no hooks, no knowledge loading, no cross-project |
| **Dotfiles repos** | (pattern) | `~/.claude/` in a git repo | Bare minimum — no orchestration layer |

**Nobody else is doing the full stack:** multi-machine fleet orchestration + cross-project inbox + conditional knowledge loading + encrypted vault + hook pipelines + session continuity + config propagation + template sanitization.

## Positioning Statement

> **Agent Fleet** is to Claude Code what Kubernetes is to Docker: the orchestration layer that makes a single-machine tool work across a fleet. OpenClaw gives you a personal AI assistant. Agent Fleet gives you an AI operations platform.

## Where They Could Converge

1. **Backend abstraction.** Agent Fleet's architecture isn't inherently Claude Code-specific. CFG-224 evaluates OpenCode as an alternative backend. OpenClaw's multi-LLM support is ahead here.
2. **Messaging integration.** Agent Fleet has one-way Telegram (AFD notify). OpenClaw's 20+ platform bridges could be valuable. Not a priority, but the architecture doesn't prevent it.
3. **Autonomous execution.** OpenClaw's heartbeat daemon is the one feature agent-fleet genuinely lacks. AFD is a step toward this but doesn't match OpenClaw's fire-and-forget autonomy. Worth monitoring.

## Recommended Messaging

For README/marketing:
- Don't position against OpenClaw directly — different categories
- Position against the "dotfiles approach" (bare git repo for `~/.claude/`)
- Lead with the multi-machine + multi-project angle — that's the unique value
- "If you use Claude Code on one machine for one project, you don't need this. If you use it across machines, projects, and teams — you do."
