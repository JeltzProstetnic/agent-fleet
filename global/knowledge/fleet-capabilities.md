<!-- consumed-by: setup/config/statusline-command.sh (context window size), foundation/project-setup.md (VoltAgent threshold, agent capabilities) -->
# Fleet Capabilities — Self-Awareness Reference

Load when: agent needs to understand its own capabilities, recommend plugins, audit agent roster gaps, or answer "can I do X?" questions.

These are YOUR features. Use them naturally ("the statusline shows..." not "your statusline shows...").

---

## Model & Platform Capabilities

What the underlying model and Claude Code platform can do. Updated when upstream changes.

| Capability | Details | Since |
|-----------|---------|-------|
| **Context window** | **1M tokens** (Opus 4.6 & Sonnet 4.6). GA since 2026-03-13. No config needed — requests >200K work automatically. Included in Max, Team, Enterprise at standard pricing. | CC 2.1.76, Anthropic 2026-03-13 |
| **Media limits** | Up to 600 images or PDF pages per request (was 100) | 2026-03-13 |
| **Effort levels** | low / medium / high. Medium is default for Opus 4.6. "ultrathink" keyword forces high effort for next turn. `max` level removed. | CC 2.1.68+ |
| **PostCompact hook** | Fires after compaction. Can checkpoint state. PreCompact abandoned (#13572 closed). | CC 2.1.76 |
| **SessionEnd timeout** | Configurable via `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS` env var (default 1.5s). | CC 2.1.74 |
| **Deferred tools** | MCP tools loaded via ToolSearch survive compaction (schema fix). | CC 2.1.76 |

## Core — Infrastructure

The foundation everything else runs on.

| Feature | What it does | Key files |
|---------|-------------|-----------|
| Multi-machine identity | Hostname detection → machine profile auto-loading | `CLAUDE.md` identity table, `machines/*.md` |
| sync.sh | Bidirectional sync: repo ↔ deployed config (setup/deploy/collect/status/stamp) | `sync.sh` |
| Vault | Single encrypted secrets store (AES-256-CBC), deploy to all targets | `secrets/vault.json.enc`, `vault-manage.sh` |
| Registry | Project catalog with parent/child relationships, machine assignments | `registry.md` |
| Hooks | SessionStart (config-check.sh), SessionEnd (auto-sync), PreToolUse (RTK token compression), PostToolUse (auto-lint, commit verify, tool install detect), UserPromptSubmit (context budget) | `global/hooks/` |
| Session system | Context persistence, 3-layer history, pending file handover, rotation, crash recovery. Shutdown checklist loaded on-demand (`session-shutdown.md`). | `session-context.md`, `rotate-session.sh` |
| Cross-project inbox | One-off task passing between projects, picked up per-session | `cross-project/inbox.md` |
| Personas | Configurable dual-persona system with semantic switching rules, Day/Night mode | `foundation/personas.md` |
| Quick commands | cls, end, lsd, lrn, afk, sub — keyword shortcuts | `CLAUDE.md` quick commands table |
| Personality Patterns | Curated dual-persona combos (Workhorse+Empath, Builder+Critic, Mentor+Peer, Strategist+Tactician, Formal+Casual). Presented during first-run setup. | `foundation/first-run-refinement.md` section 2b |
| afleet | Project launcher — pre-pull, project detection, session safety | `setup/scripts/afleet.sh` |
| Dashboard (lsd) | Project overview with task counts, disk usage, status | `cross-project/dashboard-cache.md` |
| Knowledge system | Domain files, machine files, conditional loading (on-demand), backlog convention | `domains/`, `machines/`, `knowledge/`, `reference/` |

## Core Extended — Operational Tools

Built on top of core infrastructure. Enhance the agent's operational capabilities.

| Feature | What it does | Key files |
|---------|-------------|-----------|
| Statusline: CRI | Context Rot Indicator — context window usage bar, color-coded (green→yellow→red) | `setup/config/statusline-command.sh` |
| Statusline: GPI | Grind Progress Indicator — background process progress with log enrichment | `setup/scripts/gpi.sh` |
| Statusline: PDI | Personality Disorder Indicator — active persona name, color-matched | `setup/config/statusline-command.sh` |
| lrn | Self-audit protocol — rule compliance, knowledge capture, process/architecture | `knowledge/learn-protocol.md` |
| Mobile support | Separate repo for mobile Claude app session logging | `agent-fleet-mobile` |

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

## Agent Capabilities

### Built-in (always available, 0 token cost)

| Agent | Best for |
|-------|----------|
| general-purpose | Multi-step tasks, file ops, code execution |
| Explore | Fast codebase exploration, pattern/keyword search |
| Plan | Architecture planning, implementation design (subagent workaround if plan mode broken) |

### Plugin Agents (per-project only, token cost per bundle)

| Bundle | Agents | ~Tokens | Best for |
|--------|--------|---------|----------|
| voltagent-lang | 27 | 67k | Language-specific coding |
| voltagent-infra | 16 | 37k | Docker, K8s, Terraform, CI/CD |
| voltagent-qa-sec | 15 | 33k | Testing, security audits |
| voltagent-dev-exp | 14 | 32k | Git workflows, docs, code review |
| voltagent-data-ai | 13 | 30k | ML, data pipelines, analytics |

### Task-to-Plugin Mapping

| Task type | Suggested plugin | When built-in is enough |
|-----------|-----------------|------------------------|
| Language-specific patterns | voltagent-lang | Simple code in familiar languages |
| Infrastructure/deploy | voltagent-infra | Basic Docker/CI tasks |
| Security audit | voltagent-qa-sec | Simple vulnerability checks |
| Code review | voltagent-dev-exp | Short diffs, familiar code |

**Recommendation protocol:** Per-project only. State the cost. One at a time. Night mode: defer.
