# Claude Config — Meta-Configuration Project

Claude Code configuration management across all machines and projects.

## Knowledge Loading

| Domain | File | Load when... |
|--------|------|-------------|
| IT Infrastructure | `~/.claude/domains/it-infrastructure/infra-protocol.md` | Sync scripts, hooks, deployment, VPS work |

## Key Files

| File | Purpose |
|------|---------|
| `session-context.md` | Current session state — **read first** |
| `session-history.md` | Rolling last 3 sessions — read on demand, not at startup |
| `docs/session-log.md` | Full session archive — append-only, never pruned |
| `docs/decisions.md` | Curated decisions & rationale — topical, manually maintained |
| `backlog.md` | Prioritized backlog — read when active TODOs are done |
| `registry.md` | All projects, all machines — the phone book |
| `sync.sh` | Bidirectional sync tool (setup/deploy/collect/status) |
| `README.md` | Human-readable infrastructure overview |

## Key Paths

| Path | Deploys to | Purpose |
|------|-----------|---------|
| `global/CLAUDE.md` | `~/.claude/CLAUDE.md` | Main global prompt |
| `global/foundation/` | `~/.claude/foundation/` | Core protocols (symlinked) |
| `global/domains/` | `~/.claude/domains/` | Domain knowledge (symlinked) |
| `global/reference/` | `~/.claude/reference/` | Conditional references (symlinked) |
| `global/hooks/` | `~/.claude/hooks/` | Session hooks (copied) |
| `projects/<name>/rules/` | `<project>/.claude/` | Project-specific rules (copied) |
| `setup/scripts/audit-tools.sh` | (stays in repo) | Generates per-machine tool inventory |
| `setup/scripts/rotate-session.sh` | (stays in repo) | Archives session-context → history + log |

## Cross-Project

| File | Purpose |
|------|---------|
| `cross-project/infrastructure-strategy.md` | Shared infra strategy (nuc + claude-config). VPS, multi-machine sync, NUC migration. |
| `cross-project/fmt-visibility-strategy.md` | Shared FMT visibility strategy (aIware + social). Researchers, conferences, media. |
| `cross-project/inbox.md` | One-off cross-project tasks (transient, picked up and deleted) |

## Rules for Claude

- When working on ANY project, be aware this config repo exists at `~/claude-config/`
- **Cross-project boundary**: This project may NOT write to files in other project directories (including `~/claude-config/`). To request changes elsewhere, use ONLY the cross-project inbox: `~/claude-config/cross-project/inbox.md`
- After changing any global rule or CLAUDE.md during a session, remind the user to sync
- When setting up a new project, add it to the registry (via inbox if not in claude-config)
- When infrastructure or deployment state changes, drop an inbox task for claude-config — do NOT edit `cross-project/` files directly unless your working directory IS `~/claude-config/`

## Workflow

1. Edit in this repo (canonical source)
2. `bash sync.sh deploy` to push to live locations
3. Or: edits during sessions → `bash sync.sh collect` to pull back
4. Hooks automate both directions at session start/end
