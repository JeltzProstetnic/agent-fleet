# Agent-Fleet Multi-Session Sync Plan

**Created:** 2026-03-09, assessment session
**Drift:** ~50 files, ~5000+ diff-lines between cfg-agent-fleet and agent-fleet template

## Session Plan

### S1: Backlog Bootstrap + Inbox Triage (Light-Med context)
- Create `backlog.md` with `AFT-` prefix
- Classify all ~50 drifted files into work items by category
- Process 3 inbox items at design level (what changes, what to strip)
- No file edits yet — planning only

### S2: Critical Config Propagation (Heavy context)
- `global/CLAUDE.md` (269 diff-lines) — highest security risk
- `global/reference/cross-project-rules.md` (17 lines)
- `global/reference/backlog-convention.md` (55 lines)
- `global/foundation/project-setup.md` (42 lines)
- `global/knowledge/vault-ops.md` (NEW)
- `global/foundation/session-protocol.md` (44 lines)
- All require personal data stripping

### S3: Foundation + Knowledge + Reference + Domain Files (Med-Heavy)
- ~20 files, foundation/knowledge/reference/domain categories
- `mcp-catalog.md` (342 lines) — highest security risk in this session
- `communication-policy.md` (61 lines) — high security risk

### S4: Scripts + Hooks (Heavy)
- `setup.sh` (782 lines), `sync.sh` (455 lines) — largest diffs
- Hook scripts, utility scripts, config files
- Run test suite before AND after

### S5: Test Suite Sync + Security Audit (Med-Heavy)
- Sync ~10 test files (~2000+ diff-lines combined)
- Full security audit: scan ALL template files for leaked personal data
- Fix findings

### S6: Quality Review + Docs + lrn Audit (Medium)
- Documentation coherence (README, getting-started, onboarding)
- Evaluate new template file candidates
- `lrn` audit: placeholder consistency, path consistency, completeness

## Security-Critical Files (require extra care)
1. `global/CLAUDE.md` — machine identity, mclaude paths, Telegram/AFD, Ivoclar boundary
2. `global/reference/mcp-catalog.md` — account routing, emails, MCP configs
3. `global/reference/communication-policy.md` — contact names, emails
4. `global/knowledge/vault-ops.md` — vault paths, credential targets

## Files in cfg but correctly excluded from template
- `domains/life-management/*` — personal
- `hooks/afd-relay.sh`, `hooks/afk-deactivate.sh` — personal automation
- `knowledge/afd-ops.md`, `gmail-management.md`, `jira-atlassian.md` — personal/corporate
- `machines/*` (actual configs, not _template) — per-machine
- `reference/persona-elsa.md`, `cross-project-nav.md` — personal
- `statusline.sh` (root level) — evaluate in S6

## Dependencies
S1 → S2 → S3 → S4 → S5 → S6 (sequential, each builds on prior)
