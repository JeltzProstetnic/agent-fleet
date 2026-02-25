# claude-config-template

A configuration management system for Claude Code that adds session memory, layered knowledge loading, multi-machine sync, and cross-project coordination. Works on Linux, macOS, and WSL.

## Quick Start

```bash
git clone https://github.com/anthropics/claude-config-template ~/claude-config
cd ~/claude-config && bash setup.sh
```

The `setup.sh` script will:
1. Detect your platform (Linux, macOS, or WSL)
2. Install prerequisites (git, bash)
3. Generate your user profile from interactive prompts
4. Create machine-catalog.md with detected tools
5. Set up symlinks to `~/.claude/` directories
6. Install session hooks for automatic git sync

## How It Works

Claude Code loads configuration in five layers:

```
Layer 1: Global Prompt      ← always loaded, the dispatcher
Layer 2: Foundation          ← always loaded, session rules + identity
Layer 3: Domains             ← per-project, loaded from manifest
Layer 4: References          ← on-demand, triggered by context
Layer 5: Project Rules       ← per-project, local config
```

**Layer 1** provides Claude with the dispatcher CLAUDE.md that references all other layers.
**Layer 2** contains session persistence rules, cross-project coordination patterns, and user identity.
**Layer 3** holds domain-specific protocols (IT infrastructure, development workflows, etc.) referenced by project manifests.
**Layer 4** includes conditional references for tooling, environment troubleshooting, and specialized knowledge.
**Layer 5** stores project-local rules, manifests, and session context.

## Directory Structure

```
claude-config-template/
├── README.md                    # This file
├── setup.sh                     # Installation script
├── sync.sh                      # Multi-machine sync tool
├── CLAUDE.md                    # Meta-configuration manifest
├── session-context.md           # Current state (updated per session)
├── registry.md                  # Machine and project catalog
├── machine-catalog.md           # Auto-generated tool inventory
├── backlog.md                   # Prioritized tasks
├── global/
│   ├── CLAUDE.md               # Global prompt deployed to ~/.claude/
│   ├── foundation/             # Always-loaded session protocols
│   ├── domains/                # Domain-specific knowledge (IT, dev, security, etc.)
│   ├── reference/              # On-demand conditional knowledge
│   └── hooks/                  # Session auto-sync hooks
├── projects/
│   └── example/
│       ├── CLAUDE.md           # Project manifest
│       └── rules/              # Project-local rules
└── cross-project/
    ├── infrastructure-strategy.md
    ├── fmt-visibility-strategy.md
    └── inbox.md                # Cross-machine task passing
```

## Adding Your Own Content

**Add a domain:** Create `global/domains/<domain-name>/`, add protocol files, update `global/domains/INDEX.md`, then reference from project manifests.

**Add a project:** Create `projects/<name>/`, write a `CLAUDE.md` manifest declaring which domains to load, add to `registry.md`.

**Add a machine:** Clone this repo on your new machine and run `setup.sh`. Hooks will sync configuration bidirectionally via git.

## The Machine Catalog

`setup.sh` generates `machine-catalog.md` listing installed tools on your system: Python version, Go, Node, Docker, kubectl, Terraform, AWS CLI, etc. Projects reference this file instead of probing the system at runtime, speeding up Claude's context loading.

## Multi-Machine Sync

Session hooks automate bidirectional sync via git:

```
Machine A (session ends)  ──→  GitHub  ──→  Machine B (session starts)
      git add + push              ↓         git pull + load
```

At session end, hooks commit session context, backlog updates, and machine-specific configs. At session start on another machine, hooks pull the latest state.

## Cross-Project Coordination

Three patterns enable teams to coordinate across projects:

**Inbox** (`cross-project/inbox.md`): One-off tasks, per-project. Drop a message instead of editing another project's files directly.

**Strategy files** (`infrastructure-strategy.md`, `fmt-visibility-strategy.md`): Shared decisions that affect multiple projects.

**Registry** (`registry.md`): Central phone book of all machines and projects.

## Platform Notes

| Platform | Key Differences |
|----------|-----------------|
| **Linux** | Use `xdg-open` for file operations. No path restrictions. |
| **macOS** | Use `open` for file operations. Path handling identical to Linux. |
| **WSL** | Avoid `/mnt/c/` paths (10-15x slower). Work in `~`. Set `core.autocrlf = input`. |

## License

MIT
