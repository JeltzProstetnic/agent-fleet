# Fleet Capabilities — Self-Awareness Reference

Load when: agent needs to understand its own capabilities, recommend plugins, or audit agent roster gaps.

## Core Features

These are YOUR features. Use them naturally ("the statusline shows..." not "your statusline shows...").

| Feature | What it does | Key files |
|---------|-------------|-----------|
| MCP: Serena | Code navigation, symbol search, refactoring | `.mcp.json` |
| MCP: GitHub | Repos, PRs, issues, code search | `.mcp.json` |
| MCP: Google Workspace | Gmail search/read/send/draft, filters, labels | `.mcp.json` |
| MCP: Playwright | Browser automation, screenshots, form filling | `.mcp.json` |
| MCP: Diagram | Mermaid diagram generation (file or stream) | `.mcp.json` |
| Hooks: SessionStart | `config-check.sh` — symlinks, git sync, version checks | `~/.claude/hooks/` |
| Hooks: SessionEnd | `config-auto-sync.sh` — collect changes, commit, push | `~/.claude/hooks/` |
| Statusline | Context usage indicator via `statusline.sh` | `~/.claude/statusline.sh` |
| Personas | Configurable personas with semantic switching rules | `foundation/personas.md` |
| Vault | Single source of truth for all secrets (AES-256-CBC) | `setup/secrets/vault.json.enc` |
| Session system | Context persistence, rotation, history, handoff | `session-context.md`, `rotate-session.sh` |
| Cross-project inbox | One-off task passing between projects | `cross-project/inbox.md` |

## Machine Tooling Capabilities

Per-machine tools are inventoried in `~/.claude/machines/<machine>.md`. The agent CAN use these — check the machine file before saying "I can't do X".

| Capability | Tool | Check machine file for |
|-----------|------|----------------------|
| File conversion (docx, pptx, html → md/txt) | `pandoc` | Version in Installed Tooling table |
| PDF generation | `weasyprint` | Path in Installed Tooling table |
| Encryption/decryption | `age`, `openssl` | Path in Installed Tooling table |
| Mermaid diagrams | `mmdc` (mermaid-cli) | Path in Installed Tooling table |
| Terminal multiplexing | `tmux` | Path in Installed Tooling table |
| Python scripting | `python3`, `uv`/`uvx` | Version in Installed Tooling table |
| Node.js scripting | `node`, `npm` | Version in Installed Tooling table |
| Browser automation | Playwright MCP (headless) | MCP section in Core Features above |
| File opening (GUI) | Platform-dependent | Known Issues section in machine file |

**"Can I do X?" protocol:** Before saying you can't do something, check: (1) MCP tools above, (2) machine file tooling table, (3) installed CLI tools (`which <tool>`). Only say "not available" after all three checks fail.

## Agent Capabilities

### Built-in (always available, 0 token cost)

| Agent | Best for | Notes |
|-------|----------|-------|
| general-purpose | Multi-step tasks, file ops, code execution | Default subagent |
| Explore | Fast codebase exploration, pattern/keyword search | Read-only, lightweight |
| Plan | Architecture planning, implementation design | May have upstream issues — check knowledge/plan-mode-issues.md |

### Plugin Agents (per-project only, token cost per bundle)

Available via VoltAgent and other marketplaces. Each bundle loads agent descriptions into context.

| Bundle | Agents | ~Tokens | Best for |
|--------|--------|---------|----------|
| voltagent-lang | 27 | 67k | Language-specific coding (Rust, Go, Python, TS, etc.) |
| voltagent-infra | 16 | 37k | Docker, K8s, Terraform, CI/CD |
| voltagent-qa-sec | 15 | 33k | Testing, security audits, OWASP |
| voltagent-dev-exp | 14 | 32k | Git workflows, docs, code review |
| voltagent-data-ai | 13 | 30k | ML, data pipelines, analytics |
| code-review | 1 | 10k | Automated code review |
| pr-review-toolkit | 1 | 10k | PR review with checklists |
| feature-dev | 1 | 10k | Feature scaffolding |
| hookify | 1 | 10k | Git hook generation |
| trailofbits | 1 | 10k | Static analysis, security |
| obra-superpowers | 1 | 10k | TDD workflow, debugging |
| getsentry | 1 | 10k | Error tracking integration |

### Task-to-Plugin Mapping

| Task type | Suggested plugin | When built-in is enough |
|-----------|-----------------|------------------------|
| Language-specific patterns | voltagent-lang | Simple code in familiar languages |
| Infrastructure/deploy | voltagent-infra | Basic Docker/CI tasks |
| Security audit | voltagent-qa-sec or trailofbits | Simple vulnerability checks |
| Code review | code-review or voltagent-dev-exp | Short diffs, familiar code |
| TDD workflow | obra-superpowers | Standard test frameworks |
| Error tracking | getsentry | Manual log analysis |

## Recommendation Protocol

1. **Per-project only.** Enable in `.claude/settings.local.json`, NEVER in global `settings.json`.
2. **State the cost.** Before suggesting a plugin, state its token cost (from table above). One bundle at ~30k tokens = ~15% of context window.
3. **One at a time.** Suggest one bundle per session. Don't nag after decline.
4. **Night mode: defer.** If night mode is active, note the recommendation for next session instead of suggesting a restart.
5. **Project CLAUDE.md.** Suggest adding `## Preferred Plugins` section listing approved plugins for the project.
