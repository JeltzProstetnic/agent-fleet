# claude-config-template

A configuration management system for Claude Code that adds session memory, layered knowledge loading, multi-machine sync, cross-project coordination, and self-healing protocols. Works on Linux, macOS, and WSL.

**Clone it. Run setup. Same config across all your machines and projects.**

```bash
git clone https://github.com/JeltzProstetnic/claude-config-template ~/claude-config
cd ~/claude-config && bash setup.sh
```

---

## The Problem

Three powerful AI agent products. All powerful. All missing the same things.

| Product | What it does | What's missing |
|---------|-------------|----------------|
| **Claude Code** | Terminal AI agent. Writes code, runs commands, edits files. | No memory between sessions. No multi-project awareness. No team consistency. |
| **Claude CoWork** | Desktop app for non-developers. Creates Excel, PowerPoint, docs. | No memory, no coordination, no domain knowledge management. |
| **OpenClaw** | 24/7 AI via Slack, Teams, WhatsApp. Self-hosted. | No structured knowledge. No session recovery. No cross-project coordination. |

**The pattern:** capable AI with no management layer. Like a powerful car with no GPS, no dashboard, and no service history.

---

## What This System Adds

| Capability | What this means in practice |
|------------|---------------------------|
| ✅ **Session Memory** | AI picks up where it left off. Crashes, timeouts, machine switches — nothing lost. |
| ✅ **Smart Knowledge Loading** | AI gets only relevant rules per project. Coding tasks load coding protocols. Infrastructure tasks load infra rules. |
| ✅ **Parallel Sub-Agents** | Multiple specialist AIs work simultaneously on different parts of one task. |
| ✅ **Cross-Project Inbox** | Projects pass tasks to each other automatically. No manual coordination needed. |
| ✅ **Multi-Machine Sync** | Close laptop, open desktop. Same context, same rules. Zero manual steps. |
| ✅ **Self-Healing Protocols** | Repeated mistakes auto-generate prevention rules for all future sessions. |
| ✅ **Full Audit Trail** | Every rule change is version-controlled. Who changed what, when, and why. |
| ✅ **One-Command Deploy** | New team member: clone repo, run setup, done. Same config as everyone. |

---

## Side-by-Side Comparison

| Feature | Claude Code | CoWork | OpenClaw | **This System** |
|---------|:-----------:|:------:|:--------:|:---------------:|
| AI behavior control | ❌ | ❌ | ❌ | ✅ Layered + versioned |
| Session memory | ❌ | ❌ | ⚠️ Partial | ✅ Full + crash recovery |
| Multi-agent coordination | ⚠️ Basic | ⚠️ Basic | ❌ | ✅ Coordinated specialists |
| Knowledge management | ❌ | ❌ | ❌ | ✅ 5-layer architecture |
| Multi-project support | ❌ | ❌ | ❌ | ✅ Built-in coordination |
| Multi-machine sync | ❌ | ❌ | ⚠️ 1 server | ✅ Auto-sync |
| Error prevention | ❌ | ❌ | ❌ | ✅ Self-healing protocols |
| Audit trail | ❌ | ❌ | ⚠️ Partial | ✅ Full git history |
| Team deployment | ❌ | ❌ | ❌ | ✅ One command |
| Open source | ❌ | ❌ | ✅ | ✅ |

---

## Architecture: 5 Layers of Knowledge

```
┌─────────────────────────────────────────────┐
│  Layer 1: Global Prompt                     │  ← Always loaded
│  The dispatcher (~80 lines)                 │
└─────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────┐
│  Layer 2: Foundation                        │  ← Always loaded
│  Session rules, identity, protocols         │
└─────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────┐
│  Layer 3: Domains                           │  ← Per-project
│  Coding, infrastructure, publishing, etc.   │
└─────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────┐
│  Layer 4: References                        │  ← On-demand
│  Troubleshooting, tool guides               │
└─────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────┐
│  Layer 5: Project Rules                     │  ← Per-project
│  Project-specific configuration             │
└─────────────────────────────────────────────┘
```

**Key insight:** The AI doesn't load everything. Each project declares what it needs. Context stays focused. Performance stays high.

---

## How a Session Works

```
  [Session Start]          [Working]          [Session End]
       ↓                       ↓                    ↓
  Hook pulls config    Parallel agents       Hook saves state
  Loads layers         Protocols enforced    Commits + pushes
  Restores state       State checkpointed    Next session resumes
       ↓                       ↓                    ↓
       └─────────────────────────────────────────┘
          any machine, any time — full continuity
```

---

## Quick Start

```bash
git clone https://github.com/JeltzProstetnic/claude-config-template ~/claude-config
cd ~/claude-config && bash setup.sh
```

`setup.sh` runs 6 mechanical steps, then hands off to Claude for interactive personalization:

| Step | What it does |
|------|-------------|
| 1 | Detects platform (Linux, macOS, WSL) |
| 2 | Checks prerequisites (git, `~/.claude/`) |
| 3 | Generates your user profile from interactive prompts |
| 4 | Creates `machine-catalog.md` with installed tools and versions |
| 5 | Symlinks `~/.claude/` directories to this repo |
| 6 | Installs session hooks for automatic git sync |
| 7 | **Launches Claude for interactive refinement** — personalize your profile, choose domains, set up your first project, add global rules |

Non-interactive mode: `bash setup.sh --non-interactive`

---

## Directory Structure

```
claude-config-template/
├── setup.sh                              # One-command bootstrap (Linux/macOS/WSL)
├── sync.sh                               # Bidirectional sync: deploy / collect / status
├── registry.md                           # All projects, all machines (the phone book)
├── machine-catalog.md                    # Auto-generated tool inventory (per machine)
│
├── global/
│   ├── CLAUDE.md                         # Global prompt — the dispatcher
│   ├── foundation/                       # Always loaded (7 modules)
│   │   ├── identity.md                   # Agent config, paths, machine catalog ref
│   │   ├── user-profile.md              # Name, role, style, goals
│   │   ├── session-protocol.md          # State persistence, shutdown checklist
│   │   ├── project-setup.md             # Bootstrap new projects (8 steps)
│   │   ├── protocol-creation.md         # Self-healing: mistakes → protocols
│   │   ├── roster-management.md         # Agents, skills, MCP servers per project
│   │   ├── cross-project-sync.md        # Inbox + strategy file patterns
│   │   └── first-run-refinement.md     # Post-setup interactive personalization
│   │
│   ├── domains/                          # Loaded per-project from manifest
│   │   ├── software-development/         # TDD protocol
│   │   ├── publications/                 # Publication workflow, test-driven authoring
│   │   ├── engagement/                   # Twitter/X engagement protocol
│   │   ├── it-infrastructure/            # Servers, Docker, DNS, smart home
│   │   └── _template/                    # How to write your own domain protocol
│   │
│   ├── reference/                        # On-demand (triggered by context)
│   │   ├── mcp-catalog.md               # MCP server setup + troubleshooting
│   │   ├── serena.md                     # Semantic code navigation (93% context savings)
│   │   ├── permissions.md               # Subagent global permissions
│   │   └── wsl-environment.md           # WSL-specific tips
│   │
│   └── hooks/                            # Copied to ~/.claude/hooks/
│       ├── config-check.sh              # Session start: pull config, surface inbox
│       └── config-auto-sync.sh          # Session end: commit + push
│
├── projects/
│   └── _example/rules/CLAUDE.md          # Example project manifest
│
└── cross-project/
    ├── inbox.md                          # Async task passing between projects
    ├── infrastructure-strategy.md        # Shared infra state
    └── visibility-strategy.md            # Shared visibility/engagement state
```

---

## Machine Tool Catalog

`setup.sh` auto-generates `machine-catalog.md` listing every tool on the machine:

```
# Machine Catalog: fedora-workstation

Platform: linux
Last updated: 2026-02-25

## Installed Tools

| Tool     | Path                | Version    |
|----------|---------------------|------------|
| git      | /usr/bin/git        | 2.47.1     |
| node     | /usr/bin/node       | v22.14.0   |
| python3  | /usr/bin/python3    | 3.13.2     |
| docker   | /usr/bin/docker     | 27.5.1     |
| gh       | /usr/bin/gh         | 2.67.0     |
| pandoc   | /usr/bin/pandoc     | 3.1.11.1   |
```

Projects reference this catalog instead of probing the system. No `which` commands. No version detection at runtime. The catalog is the source of truth.

---

## Multi-Machine Sync

```
Machine A (session ends)              Machine B (session starts)
┌────────────────────────┐            ┌────────────────────────┐
│ config-auto-sync.sh    │            │ config-check.sh        │
│   ├── sync.sh collect  │            │   ├── git pull         │
│   ├── git commit       │ ─GitHub──► │   ├── surface inbox    │
│   └── git push         │            │   └── verify symlinks  │
└────────────────────────┘            └────────────────────────┘
```

No machine is special. Clone the repo, run `setup.sh`, and any machine becomes a full participant.

---

## Cross-Project Coordination

**Inbox** (`cross-project/inbox.md`) — One-off tasks targeting a specific project. Drop a message, the project picks it up at next session start, deletes after integrating.

**Strategy files** — Persistent shared state between projects that overlap (e.g., infrastructure + config, authoring + social media). Single source of truth.

**Registry** (`registry.md`) — The phone book. Every project, every machine, current status.

---

## Included Domains

| Domain | Files | What it enforces |
|--------|-------|-----------------|
| **Software Development** | `tdd-protocol.md` | Test-driven development with explicit escape hatches |
| **Publications** | `publication-workflow.md`, `test-driven-authoring.md` | Markdown-to-LaTeX-to-PDF pipeline, content integrity testing |
| **Engagement** | `twitter-engagement-protocol.md` | Discourse scanning, reply drafting, thread etiquette, growth strategy |
| **IT Infrastructure** | `infra-protocol.md` | Server management, Docker conventions, DNS/SSL, service coordination |

Add your own: copy `global/domains/_template/example-protocol.md`, adapt, add to INDEX.

---

## Platform Notes

| | Linux | macOS | WSL |
|--|-------|-------|-----|
| **Open files** | `xdg-open` | `open` | `powershell.exe Start-Process` |
| **Symlinks** | `ln -sf` | `ln -sf` | `ln -sf` (within WSL fs) |
| **Performance** | Native | Native | Avoid `/mnt/c/` (10-15x slower) |
| **Git line endings** | N/A | N/A | `core.autocrlf input` |
| **Package manager** | varies | Homebrew | apt |

---

## cc-mirror — Multi-Agent Variant System

This system is designed to work with [cc-mirror](https://github.com/nicobailey/cc-mirror), a multi-agent variant system for Claude Code that provides:

- **Named variants** — separate configs for different roles or projects (e.g., `mclaude`, `devops`, `writer`)
- **VoltAgent subagent roster** — 129+ specialized agents (infrastructure, QA, data/AI, research, business, etc.) selectable per variant
- **Per-variant MCP server configuration** — each variant gets its own tool stack
- **Plugin management** — install, update, and compose skill collections per variant
- **Custom launchers** — named entry points with automatic update checking

Works with vanilla Claude Code too — just uses `~/.claude/` paths instead of `~/.cc-mirror/<variant>/`.

---

## License

MIT — see [LICENSE](LICENSE).
