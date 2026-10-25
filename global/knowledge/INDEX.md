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
| `learn-protocol.md` | — (deprecated) | Redirect to `skills/lrn/SKILL.md` |
| `risk-analysis-protocol.md` | Risk gate blocks an edit (RISK_GATE in stderr) | Subagent prompt, clearance protocol, T1 file inventory, known failure modes |
| `responsibility-modeling.md` | Documenting responsibility/ownership/governance, or a RACI matrix is proposed | Why RACI is rejected (7 failure modes); single-owner/DACI/STO/DARE/RAPID/Team-Topologies alternatives |
| `glib-idle-callback-pattern.md` | GLib/GTK idle or timeout callback busy-loop, 100% CPU in a GTK app | The return-True one-shot `idle_add` pitfall and the `(callback(), False)[1]` fix |
| `hook-behavior.md` | Hook debugging, platform-specific hook issues | UserPromptSubmit gaps, PreToolUse subagent support, urandom quirks |
| `dev-browser-ops.md` | Using dev-browser skill or browser automation | Startup, Chromium drift fix, session persistence |
| `age-encryption.md` | Encryption tasks involving age/pyrage | age CLI TTY limitation, pyrage alternative, passphrase handling |
| `fleet-capabilities.md` | Self-awareness, plugin recommendation, agent roster gaps | Core features catalog, agent capabilities, plugin mapping, recommendation protocol |
| `fleet-issue-protocol.md` | Filing GitHub issue on agent-fleet | Issue template, label conventions, upstream vs local |
| `follower-mode.md` | SESSION_LOCKED or SESSION_LOCKED_REMOTE in systemMessage | Session locking, follower behavior, lock release |
| `konsole-tabs.md` | Konsole tabs, qdbus, terminal tab operations | D-Bus commands, session safety, tab lifecycle |
| `statusline-ops.md` | Statusline editing, GPI, statusline deployment | GPI CLI, statusline format, deployment procedure |
| `vault-ops.md` | Vault ops, credentials, deploy secrets, encrypt/decrypt | vault-manage.sh usage, passphrase handling, deploy targets |
| `audit-protocol.md` | Audit, self-audit, meta-audit | 3 lines of defense, 8-step workflow, system invariants, audit log format |
| `audit-pattern-fleet.md` | P4 fleet audit orchestration | Multi-agent audit pattern, parallel phases, coverage |
| `gmail-management.md` | Gmail triage, inbox management, email | Triage protocol, draft lifecycle, label taxonomy, spam strategy |
| `scrollback-fix.md` | Scrollback issues, terminal buffer overflow | Root cause, terminal-specific fixes, deployment checklist |
| `rule-writing.md` | Writing or proposing new rules | Quality checklist, anti-patterns, process |
| `deliverable-authoring.md` | Before the first draft of any stakeholder-facing deliverable | Clarify-before-building, one audience per document, no process-meta, status fidelity, sourced numbers |
| `needs-to-requirements.md` | Eliciting or writing user needs, requirements, an MVP scope, a build plan | The four-document chain, theme clustering, `UN-nnn`/`SR-xnn` formats, category M/D/I, traceability, status inheritance |
| `user-roles-and-personas.md` | Writing user needs, personas, audience analysis, role-scoped UI or notifications | Three kinds of role, nesting/positional/situational, union-not-selector, personas as real named people, coverage matrices |
| `vertical-slicing.md` | Cutting a build order, roadmap or release plan | Slice anatomy, recording-vs-reasoning split, cross-cutting boundaries, coverage matrix, failure modes |
| `project-economics.md` | ROI sections, portfolio ranking, continue/kill arguments, business-case features | eNPV, ETC/EAC, productivity index, payback, margin, drift index; assumptions as owned records; alerting |
| `anti-chain-state.md` | Anti-chain state, cooldown mutation, "tried vs did", weighted-random state bug | The Bug, The Pattern, Where This Applies |
| `systemd-memory-accounting.md` | systemd service memory alarm, suspected leak, OOM post-mortem, container memo… | The trap, Measurement that established it, Diagnostic recipe |
| `prose-register.md` | Writing, revising or briefing any human-facing text longer than a few lines | AI-tell lists, structural slop, sliding-window rhythm budget, claim fidelity |
| `print-production.md` | Preparing a print interior or cover for a printer / print-on-demand | Ink limits, bleed, what the press does to the file |
| `kdp-publishing.md` | Publishing a paperback, hardcover or ebook on Amazon KDP | Trim/spine/cover math, barcode zone, metadata and upload traps |
| `cover-design.md` | Designing or reviewing a book cover | Genre conventions, title legibility, positioning |
| `office-templates.md` | Producing any DOCX / PDF / PPTX deliverable | Fleet office template: palette, fonts, logo, builders |
| `audit-domains.md` | Regulatory audit simulation, academic peer review, multi-domain audit personas | Meta-pattern, domain catalog D1-D6, cross-domain principles |
| `presentation-design.md` | Building or reviewing any slide deck / `.pptx` | ≤7 words per slide, deck-vs-companion-document, tooling reality, image-cap-safe render verification |
| `word-editing-extraction.md` | Word inline editing, .docx review extraction, author review round | Three Mark Types, Extraction Protocol, Generation Protocol (.docx output) |
| `test-isolation-guards.md` | Test isolation, live service leak, env var prod default, conftest guard | The Bug, The Fix: conftest.py Autouse Guard, The Anti-Pattern |
| `pglite-bootstrap.md` | PGlite bootstrap, IndexedDB idempotency, PGlite-in-vitest, Recharts mock | Bootstrap Idempotency (IndexedDB Persistence), PGlite-in-Vitest Harness, Schema-Version Reset-on-Upgrade Migration |
| `risk-management.md` | Risk tiers, E2E test requirements, privacy scrub, IT security compliance | Risk Tiers, T1 — Critical Infrastructure, T2 — Deployment Pipeline |

## Adding New Knowledge Files

1. Create `<tool-or-skill>.md` in this directory
2. Add a conditional loading entry in `global/CLAUDE.md` (see "Conditional loading" section)
3. Update this INDEX
4. Format: filename is lowercase, hyphens for spaces (e.g., `dev-browser-ops.md`)
5. Propagate to template if generic (strip personal details)
