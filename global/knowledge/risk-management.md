<!-- updates: global/CLAUDE.md (conditional trigger table), README.md (risk section) -->
<!-- consumed-by: global/hooks/risk-gate.sh (T1 classification), setup/tests/test-e2e-deployment.sh (E2E verification) -->
# Risk Management System

Unified risk classification and enforcement for agent fleet infrastructure changes.

## Risk Tiers

| Tier | Name | Scope | Enforcement | Recovery |
|------|------|-------|-------------|----------|
| **T1** | Critical Infrastructure | Launchers, live settings, sync engine, MCP config | PreToolUse block → risk subagent clearance | Manual, minutes to hours |
| **T2** | Deployment Pipeline | Setup scripts, hooks, install flow, settings template | Post-edit flag → E2E test required before merge | Rollback via git, minutes |
| **T3** | Propagation | Global files tracked in template-sync-manifest | Post-edit flag → template-push dry-run | Re-deploy from repo |
| **T4** | Privacy | Any content leaving the repo (GitHub issues, PRs, template push) | Pre-action scrub for PII patterns | Cannot recall once published |

## T1 — Critical Infrastructure

**Files:** `~/.local/bin/mclaude`, `~/.local/bin/afleet`, `$CLAUDE_CONFIG_DIR/settings.json`, `~/.mcp.json`, `sync.sh`

**Enforcement:** `risk-gate.sh` (PreToolUse hook). Blocks Write/Edit to T1 files unless a time-limited clearance file exists. Clearance requires a risk analysis subagent to assess the change.

**Protocol:**
1. Agent attempts edit → hook blocks with `RISK_GATE TIER 1`
2. Agent loads this file + `risk-analysis-protocol.md`
3. Risk subagent evaluates: what changes, what breaks if wrong, rollback path
4. If acceptable: write clearance file (valid 10 minutes)
5. Retry edit → hook allows

## T2 — Deployment Pipeline

**Files:** `setup/install.sh`, `setup/install-base.sh`, `setup/configure-claude.sh`, `setup/lib.sh`, `setup/scripts/upgrade.sh`, `setup/config/settings.json`, `setup/config/*.json`, `global/hooks/*.sh`, `setup/scripts/setup-project-roster.sh`

**Enforcement:** Post-edit awareness. After editing any T2 file, the agent must:
1. Run `bash setup/tests/run.sh` (local test suite)
2. Run E2E deployment test in Podman: `bash setup/scripts/e2e-podman.sh --source ~/agent-fleet` (after `sync.sh template-push --commit`, via `tmux-launch.sh`)
3. Both must pass before committing

**Podman runner, and testing edits BEFORE they ship (2026-09-28, CFG-675 a):** `bash setup/scripts/e2e-podman.sh` clones the PUBLISHED template, so it never sees a local edit. `e2e-podman.sh --source ~/agent-fleet` ships the local working tree instead (uncommitted edits included, extracted `--no-same-owner`), and the marker records `source=… head=… dirty=…`. Working order used 2026-09-28: edit in cfg → `sync.sh template-push --commit` (local template commit, unpushed) → `e2e-podman.sh --source ~/agent-fleet --keep` via `tmux-launch.sh` → behavioural check inside the kept container (`podman cp` a script, `podman exec`) → push. ⚠ A green E2E does not prove the upgrade phase ran — read the log for `Upgraded:` (CFG-675 d).

**Automated detection:** The SessionEnd hook checks `git diff --name-only` for T2 file patterns and warns if E2E tests weren't run.

## T3 — Propagation

**Files:** Everything under `global/` tracked in `template-sync-manifest.md`

**Enforcement:** After editing manifest-tracked files:
1. Run `bash sync.sh template-push --dry-run`
2. If changes detected: run `bash sync.sh template-push --commit` for Category 1-2 files
3. Category 3 files (CLAUDE.md, personas, mcp-catalog, sync.sh) → create inbox task for manual review

**Automated detection:** SessionEnd hook Phase 0.8 runs drift detection and logs `TEMPLATE_PROPAGATION_NEEDED` for next session.

## T4 — Privacy

**Scope:** Content crossing the repo boundary — GitHub issues, PRs, template pushes, any public-facing output.

**Enforcement:**
- Template push: `template-push.sh` runs `.push-filter.conf` patterns (personal paths, tokens, hostnames, email addresses)
- GitHub issues: `fleet-issue.sh` scrubs PII before filing (paths → `~/`, tokens → `[REDACTED]`, hostnames → generic)
- PR descriptions: Manual review required (no automated scrub yet)

**Patterns scrubbed:**
- Home paths (`/home/<user>/` → `~/`)
- Hostnames (machine-specific → `<hostname>`)
- Email addresses (personal → `<email>`)
- API tokens / keys (any 40+ char alphanumeric → `[REDACTED]`)
- IP addresses (private ranges → `<ip>`)

## E2E Test Requirements

| Change Type | Required Tests | How to Run |
|-------------|---------------|------------|
| Hook changes | `test-pretooluse-hooks.sh`, `test-config-check.sh` | `bash setup/tests/run.sh` |
| Setup/install changes | E2E in Podman | `e2e-podman.sh --source ~/agent-fleet` |
| Upgrade path changes | E2E upgrade path in Podman | `e2e-podman.sh --source ~/agent-fleet --test upgrade-path` |
| Settings template changes | Deploy + verify | `sync.sh deploy && bash setup/tests/test-sync.sh` |
| sync.sh changes | Full sync test suite | `bash setup/tests/test-sync.sh` |

## Audit Trail

All risk decisions are tracked:
- T1 clearances: `/tmp/.risk-gate-clearance-*` (ephemeral, 10-minute TTL)
- T2 E2E results: Podman E2E log output in session context
- T3 propagation: `sync.sh template-push` output in commit messages
- T4 privacy: `.push-filter.conf` patterns + `fleet-issue.sh` scrub log
- Rule changes: git history with rationale in commit messages

## IT Security Compliance

This risk management system provides:
- **Change control:** All infrastructure changes gated by tier-appropriate verification
- **Least privilege:** Hooks enforce boundaries (cross-project writes blocked, T1 edits blocked)
- **Audit trail:** Every change in git with author, timestamp, and rationale
- **Automated testing:** 1,100+ unit tests + E2E deployment tests in isolated rootless Podman containers
- **Secret management:** Encrypted vault, GUI-only passphrase entry, no plaintext in git
- **Privacy protection:** PII scrub on all outbound content (GitHub, template push)
- **Rollback capability:** Every deployment has a git-based rollback path
