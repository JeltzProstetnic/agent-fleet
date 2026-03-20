<!-- agent-fleet-managed — DO NOT overwrite with /init. This CLAUDE.md is maintained by agent-fleet. -->
# Claude Config — Meta-Configuration Project

Claude Code configuration management across all machines and projects.

## Knowledge Loading

| Domain | File | Load when... |
|--------|------|-------------|
| IT Infrastructure | `~/.claude/domains/it-infrastructure/infra-protocol.md` | Sync scripts, hooks, deployment, VPS work |

## Key Files

| File | Purpose |
|------|---------|
| `session-context.md` | Current session state — **read first** (gitignored, created at first use) |
| `session-history.md` | Rolling last 3 sessions — read on demand (gitignored, created by rotation) |
| `docs/session-log.md` | Full session archive — append-only, never pruned |
| `docs/decisions.md` | Curated decisions & rationale — topical, manually maintained |
| `backlog.md` | Prioritized backlog (gitignored, created by first-run refinement) |
| `registry.md` | All projects, all machines (gitignored, created by first-run refinement) |
| `sync.sh` | Bidirectional sync tool (setup/deploy/collect/status) |
| `setup/secrets/` | Encrypted token vault scaffold |
| `setup/vps/` | VPS-specific bootstrap and skills |
| `README.md` | Human-readable infrastructure overview |

## Key Paths

| Path | Deploys to | Purpose |
|------|-----------|---------|
| `global/CLAUDE.md` | `~/.claude/CLAUDE.md` | Main global prompt |
| `global/foundation/` | `~/.claude/foundation/` | Core protocols (symlinked) |
| `global/domains/` | `~/.claude/domains/` | Domain knowledge (symlinked) |
| `global/reference/` | `~/.claude/reference/` | Conditional references (symlinked) |
| `global/knowledge/` | `~/.claude/knowledge/` | Operational knowledge (symlinked) |
| `global/machines/` | `~/.claude/machines/` | Per-machine config (symlinked) |
| `global/hooks/` | `~/.claude/hooks/` | Session hooks (copied) |
| `setup/projects/<name>/rules/` | `<project>/.claude/` | Project-specific rules (copied) |
| `setup/scripts/audit-tools.sh` | (stays in repo) | Generates per-machine tool inventory |
| `setup/scripts/rotate-session.sh` | (stays in repo) | Archives session-context → history + log |

## Cross-Project

| File | Purpose |
|------|---------|
| `cross-project/infrastructure-strategy.md` | Shared infra strategy. VPS, multi-machine sync, server migration. |
| `cross-project/visibility-strategy.md` | Shared visibility strategy. Researchers, conferences, media. |
| `cross-project/inbox.md` | One-off cross-project tasks (transient, picked up and deleted) |

## Statusline (Context Bar)

Claude Code displays a live context usage indicator in the terminal status bar, showing how much of the context window is consumed.

**What it shows:** `[Model] ▓▓▓▓░░░░░░ 108k/200k (54%) | Assistant`
- Model name (e.g., Claude Opus 4)
- Visual fill bar (10 segments)
- Used tokens / total tokens (in thousands)
- Percentage used
- Active persona name (if `~/.claude/.active-persona` exists)

**Color coding:**
- Green: <70% context used
- Yellow: 70-89% context used
- Red: 90%+ context used (consider wrapping up or compacting)

**How it works:**
- Source: `setup/config/statusline-command.sh`
- Deployed to: `~/.claude/statusline-command.sh` (by `configure-claude.sh`, Step 4)
- Activated by: `statusLine` block in `settings.json` pointing to `bash ~/.claude/statusline-command.sh`
- Claude Code pipes JSON context data to the script via stdin; the script outputs the formatted bar

**Persona display:** The script reads `~/.claude/.active-persona` (a single-line file written by Claude) and appends the persona name in its configured color. If the file doesn't exist, the persona indicator is omitted.

## Rules for Claude

- When working on ANY project, be aware this config repo exists at `~/agent-fleet/`
- After changing any global rule or CLAUDE.md during a session, remind the user to sync
- When setting up a new project, add it to the registry
- When infrastructure or deployment state changes, update `cross-project/infrastructure-strategy.md`
- **Hook source editing hazard:** Files in `global/hooks/` are deployed (copied) to `~/.claude/hooks/`. The SessionEnd auto-sync hook runs `sync.sh collect`, which copies deployed hooks BACK to `global/hooks/`, overwriting any uncommitted edits. When editing hook sources, commit immediately after editing — do not leave them uncommitted across tool calls.

## Workflow

1. Edit in this repo (canonical source)
2. `bash sync.sh deploy` to push to live locations
3. Or: edits during sessions → `bash sync.sh collect` to pull back
4. Hooks automate both directions at session start/end
