<!-- consumed-by: setup/config/statusline-command.sh (context window size), foundation/project-setup.md (VoltAgent threshold, agent capabilities) -->
# Fleet Capabilities — Self-Awareness Reference

Load when: agent needs to understand its own capabilities, recommend plugins, audit agent roster gaps, or answer "can I do X?" questions.

These are YOUR features. Use them naturally ("the statusline shows..." not "your statusline shows...").

---

## Model & Platform Capabilities

What the underlying model and Claude Code platform can do. Updated when upstream changes.

### Active Opus model

The fleet runs whichever Opus version `mclaude` (via `cc-mirror`) bundles at install time. The four relevant models today (Fable 5 is selectable, never the bundled default):

| Model | Default in CC version range | 1M context | Fast Mode (`/fast`) | Notes |
|-------|----------------------------|-----------|--------------------|-------|
| **Opus 4.6** | CC 2.1.76 – 2.1.110 (and any explicit pin) | Yes (native) | **Yes** — 2.5x speed at 6x cost, CC 2.1.36+ | Effort default `high` (raised from `medium` in 2.1.111). Knowledge cutoff Jan 2025. |
| **Opus 4.7** | CC 2.1.111 – 2.1.152 | Yes (native) | **No** — Anthropic did not carry Fast Mode forward | Effort default `xhigh` (since 2.1.117). Knowledge cutoff Jan 2026. |
| **Opus 4.8** | CC 2.1.153+ (current default; released 2026-05-28) | Yes (native) | **Yes** — 3x cheaper than 4.6 Fast Mode ($10/M in, $50/M out) | ~4x less hallucination. Effort controls. Dynamic parallel subagent workflows. Same base pricing as 4.6/4.7 ($5/$25). Knowledge cutoff May 2025. |
| **Fable 5** | Never the default — selectable in CC 2.1.170+ (alias `fable`, id `claude-fable-5`) | Yes (native) | No | Preview flagship (announced 2026-06-09), tier above Opus. SOTA on most benchmarks; auto-falls back to Opus 4.8 in high-risk domains. $10/M in, $50/M out. See the Fable 5 section below. |

Run `mclaude --version` to see the installed CC version, then map via the table. To switch: `cc-mirror update mclaude --claude-version <X> --no-tweak` (e.g. `2.1.110` for Opus 4.6).

### Fable 5 (preview model, June 2026)

**Claude Fable 5** — Anthropic flagship announced 2026-06-09; the safeguarded, generally-available version of internal **Mythos 5**. SOTA on most benchmarks (SWE, knowledge work, vision, scientific research), built for long-running multi-stage async tasks. In high-risk domains (cyber/bio/chem) it blocks and **auto-falls back to Opus 4.8** (<5% of sessions; toggle via `/config` → "switch models when a message is flagged"). API price **$10/M in, $50/M out**.

- **Access:** selectable in **Claude Code v2.1.170+**. Alias `fable`, full id `claude-fable-5`.
- **Pricing/credits:** free on Pro/Max/Team/Enterprise **June 9–22**; **from June 23** removed from those plans → use then requires metered usage credits (API rates). Anthropic says it aims to restore it to subscription plans later — attributes this to **capacity**, not public pressure. API access unaffected throughout. (Separate, do-not-conflate: a **June 15** change moves Agent SDK / `claude -p` headless / GH-Actions usage to a separate monthly credit pool.)
- **Use it without losing the Opus 4.8 default (recommended pattern):** define a Fable **subagent** (agent definition with `model: claude-fable-5`) — invoked on demand, no manual toggling. Other options: a dedicated session/tab launched with `--model fable`, or the `/model` picker + press **`s`** (session-only). Plain `/model fable` (Enter) **persists** the new default — avoid. Preview/non-default model IDs pass through to `--model`/subagent `model` as full strings but must be enabled for the account.
- **Update path:** `cc-mirror update <launcher> --claude-version <ver> --no-tweak` (NOT `claude update`). The 2.1.168→2.1.170 step pulled the substantial **2.1.169** changeset (new `post-session` hook, `--safe-mode`/`CLAUDE_CODE_SAFE_MODE`, `/cd`, `disableBundledSkills`, 50+ permission/hook/MCP/settings fixes); post-update validation should cover SessionStart, PreToolUse exit-2 guards, PostToolUse, MCP, statusline, permissions, and `CLAUDE_CONFIG_DIR`. **Correction:** Stop/SubagentStop `additionalContext` is **NOT** present in 2.1.169/2.1.170 (verified-absent). (Sources: anthropic.com/news/claude-fable-5-mythos-5; code.claude.com/docs/en/changelog.)

### Creative-writing capability (delegation guidance)

Per EQ-Bench Creative Writing v3 (Jun 2026): Opus 4.7 tops creative writing (Elo 2206); Opus 4.8 is third on creative (2031) but #1 on EQ General (2116), ahead of GPT-5.5. Sonnet 4.6 is a cheaper ~85% alternative but is **not** a creative upgrade over Opus — "delegate creative writing to Sonnet" is a downgrade, not an optimization. Implication: final creative/persuasive prose should be delegated to an **Opus** writer subagent, not Sonnet. (Source: social session 2026-06-09.)

### Platform capabilities

| Capability | Details | Since |
|-----------|---------|-------|
| **Context window** | **1M tokens** for Opus 4.7, Opus 4.6, Sonnet 4.6, Sonnet 4.5 — native, no beta flag. Haiku 4.5 = 200k. GA since 2026-03-13. **CC bug:** CC sometimes reports `context_window_size=200000` for 1M-capable models; statusline-command.sh overrides via `MODEL_WINDOWS` table. CC 2.1.113 fixed Opus 4.7 sessions inflating `/context` percentages and autocompacting too early. | CC 2.1.76 (1M GA), CC 2.1.113 (Opus 4.7 fix) |
| **Media limits** | Up to 600 images or PDF pages per request (was 100) | 2026-03-13 |
| **Effort levels** | low / medium / high / xhigh. Default per model: Opus 4.6 = `high`, Opus 4.7 = `xhigh`, Opus 4.8 = TBD (verify after CC update). "ultrathink" keyword forces high effort for next turn. `max` level removed. | CC 2.1.68+ (effort), 2.1.111 (xhigh), 2.1.117 (defaults raised) |
| **PostCompact hook** | Fires after compaction. Can checkpoint state. PreCompact abandoned (#13572 closed). | CC 2.1.76 |
| **SessionEnd timeout** | Configurable via `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS` env var (default was 1.5s, we set 10000). | CC 2.1.74 |
| **Deferred tools** | MCP tools loaded via ToolSearch survive compaction (schema fix). | CC 2.1.76 |

## Core — Infrastructure

The foundation everything else runs on.

| Feature | What it does | Key files |
|---------|-------------|-----------|
| Multi-machine identity | Hostname detection → machine profile auto-loading | `CLAUDE.md` identity table, `machines/*.md` |
| sync.sh | Bidirectional sync: repo ↔ deployed config (setup/deploy/collect/status/stamp) | `sync.sh` |
| Vault | Single encrypted secrets store (AES-256-CBC), deploy to all targets | `secrets/vault.json.enc`, `vault-manage.sh` |
| Registry | Project catalog with parent/child relationships, machine assignments | `registry.md` |
| Template sync | Personal config repo → public agent-fleet repo with push-filter sanitization | `sync.sh deploy`, `.push-filter.conf` |
| Hooks | SessionStart (config-check.sh, 34 checks), SessionEnd (auto-sync), PreToolUse (AFD relay), PostToolUse (auto-lint for Write/Edit), UserPromptSubmit (AFK deactivate, context budget) | `global/hooks/` |
| Session system | Context persistence, 3-layer history, pending file handover, rotation, crash recovery. Shutdown checklist loaded on-demand (`session-shutdown.md`) to save ~1k tokens/session. | `session-context.md`, `rotate-session.sh` |
| Cross-project inbox | One-off task passing between projects, picked up per-session | `cross-project/inbox.md` |
| Personas | Bartl (default), Elsa (frustration trigger), Day/Night mode (17:00/20:00 auto-switch) | `foundation/personas.md` |
| Quick commands | cls, end, lsd, lrn, lrnd, afk, sub — keyword shortcuts | `CLAUDE.md` quick commands table |
| Personality Patterns | Curated dual-persona combos (Workhorse+Empath, Builder+Critic, Mentor+Peer, Strategist+Tactician, Formal+Casual). Presented during first-run setup. | `foundation/first-run-refinement.md` section 2b |
| afleet | **Mandatory** project launcher — pre-pull, project detection, session safety. Sets `AFLEET_LAUNCHED=1` + `AFLEET_PROJECT`. Direct mclaude triggers Check 27 warning. | `setup/scripts/afleet.sh` |
| Dashboard (lsd) | Project overview with task counts, disk usage, status | `cross-project/dashboard-cache.md` |
| Knowledge system | Domain files, machine files, conditional loading (on-demand: NAS, konsole tabs, shutdown checklist), backlog convention | `domains/`, `machines/`, `knowledge/`, `reference/` |

## Core Extended — Operational Tools

Built on top of core infrastructure. Enhance the agent's operational capabilities.

| Feature | What it does | Key files |
|---------|-------------|-----------|
| Statusline: CRI | Context Rot Indicator — context window usage bar, color-coded (green→yellow→red) | `setup/config/statusline-command.sh` |
| Statusline: GPI | Grind Progress Indicator — background process progress with log enrichment, parallel display | `setup/scripts/gpi.sh`, `~/.claude/.gpi-state.json` |
| Statusline: PDI | Personality Disorder Indicator — active persona name, color-matched | `setup/config/statusline-command.sh` |
| lrn | Self-audit protocol — rule compliance, knowledge capture, process/architecture | `skills/lrn/SKILL.md` |
| Mobile support | Separate repo for mobile Claude app session logging | `agent-fleet-mobile` |
| VPS deployment | Terminal + chat UI served from your configured VPS domain | `vps/` |

## Life OS Packages

Domain-specific systems that serve the user's life management needs. Each is a self-contained subsystem with its own scripts, data, and conventions.

| Package | Full name | What it does | Key files |
|---------|-----------|-------------|-----------|
| **DMS** | Document Management System | Document catalog with storage abstraction, intake protocol, validation, Dropbox sync | `dms/` — catalogs, scripts, naming convention, storage map |
| **FMS** | File Management System | Drop folder model across machines (`~/__FMS__/`, NAS `__FMS__/`), auto-ingest scanner, category subfolders | `dms/scripts/fms-intake.sh`, `dms/scripts/dms-file.sh` |
| **PMS** | People Management System | JSONL people registry, graph viz (Cytoscape.js), relationship tracking | `people/people-db.sh`, `people/people.jsonl` |
| **AFD** | Agent Fleet Daemon | VPS-hosted coordination server — task endpoints, session locking, Telegram bot (bidirectional), ntfy push notifications, AFK mode, CLI + bash lib | `afd/` — server, CLI, lib, assets |

---

## MCP Servers (Claude Code infrastructure, not agent-fleet features)

MCP servers are configured per-machine in `.mcp.json`. They extend Claude Code's capabilities but are not part of agent-fleet itself. The fleet manages their configuration via vault deploy and machine files.

Full catalog, routing rules, and troubleshooting: `reference/mcp-catalog.md`.

## Machine Tooling Capabilities

Per-machine tools are inventoried in `~/.claude/machines/<machine>.md`. Check before saying "I can't do X".

| Capability | Tool | Check machine file for |
|-----------|------|----------------------|
| File conversion | `pandoc` | Version in Installed Tooling table |
| PDF generation | `weasyprint` | Path in Installed Tooling table |
| Encryption/decryption | `age`, `openssl` | Path in Installed Tooling table |
| Mermaid diagrams | `mmdc` (mermaid-cli) | Path in Installed Tooling table |
| Terminal multiplexing | `tmux` | Path in Installed Tooling table |
| Python/Node scripting | `python3`, `uv`/`uvx`, `node`, `npm` | Version in Installed Tooling table |
| Browser automation | Playwright MCP (headless) | MCP catalog |
| File opening (GUI) | Platform-dependent | Known Issues in machine file |

**"Can I do X?" protocol:** Check (1) MCP tools, (2) machine file tooling table, (3) `which <tool>`. Only say "not available" after all three fail.

### Match work to machine ergonomics

Capability is not the only constraint — physical ergonomics matter. Default coding and typing-intensive work to chair-equipped machines (WSL, Deck 2 docked at the living-room TV, office). Avoid spinning up keyboard-intensive sessions on Steam Deck 1 unless the user is physically there with a keyboard — Deck 1 is a bedroom device (no chair, no permanent keyboard, in-bed evening/night use), best for read-only / quick-touch / observation, ambient sessions, or remote-driven work coordinated from another machine via SSH. (Source: p0rn session 2026-06-08.)

## Agent Capabilities

### Built-in (always available, 0 token cost)

| Agent | Best for |
|-------|----------|
| general-purpose | Multi-step tasks, file ops, code execution |
| Explore | Fast codebase exploration, pattern/keyword search |
| Plan | Architecture planning, implementation design (subagent workaround, CFG-16) |

### Plugin Agents (per-project only, token cost per bundle)

| Bundle | Agents | ~Tokens | Best for |
|--------|--------|---------|----------|
| voltagent-lang | 27 | 67k | Language-specific coding |
| voltagent-infra | 16 | 37k | Docker, K8s, Terraform, CI/CD |
| voltagent-qa-sec | 15 | 33k | Testing, security audits |
| voltagent-dev-exp | 14 | 32k | Git workflows, docs, code review |
| voltagent-data-ai | 13 | 30k | ML, data pipelines, analytics |

**Recommendation protocol:** Per-project only. State the cost. One at a time. Night mode: defer.

---

## Recovery & Diagnostics

| Command | What it does |
|---------|-------------|
| `afleet doctor` | Health check: CC binary, settings.json, MCP servers (TCP probe), hooks (syntax + exec), session locks, git state |
| `afleet recover` | Auto-fixes: permissions, stale locks, redeploys via `sync.sh deploy` |
| `afleet rollback N` | Resets config repo by N commits + redeploys. `--dry-run` to preview, `--yes` to skip prompt |
| `afleet safe-mode` | Launches bare CC with no hooks/MCP/plugins (temp config dir, auto-cleaned) |

**CC diagnostic technique:** When CC shows "Interrupted" or "Execution error" with no detail, use `claude --print "test" --output-format json` — this exposes the actual error (429, MAX_TIMEOUT_MS, MCP hang, etc.) that the normal UI hides. This was the breakthrough in the 2026-03-20 WSL lockout incident.
