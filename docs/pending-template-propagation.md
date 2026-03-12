Action: act

# Remaining Template Propagation Items

S1a committed (777e606) covered the bulk files. S2 (this session) completed items 1-8.

## 1. learn-protocol.md fix hierarchy (inbox line 67)
- [x] learn-protocol.md: 5-tier fix hierarchy with bias check — DONE (8896575)
- [x] CLAUDE.md conditional trigger for learn-protocol — already present
- statusline-ops.md: DONE in S1a

## 2. drafts/ convention + fleet-capabilities + config-check (inbox line 68)
- [x] CLAUDE.md: drafts/ rule extension, step 8 populate session-context — DONE (23aa11e, 80eb14d)
- [x] project-setup.md: drafts/ dir in setup steps — DONE (80eb14d)
- [x] config-check.sh: .txt in Check 15, ACT_PENDING warning, TMUX_ACTIVE — DONE (b191369)
- [x] fleet-capabilities.md: 3-tier grouping — N/A (template intentionally simplified, Life OS is personal)

## 3. collect guard + step 10 + Check 18 removal (inbox line 70)
- [x] sync.sh collect: per-file timestamp guard for project rules (CFG-128) — DONE (5b99cf7)
- [x] CLAUDE.md step 10: human-readable startup/shutdown messages — DONE (23aa11e)
- [x] config-check.sh: Check 15 git-behind hint, Check 18 AFLEET_DASHBOARD removed — DONE (b191369)
- [x] Removed duplicate "plain-language" convention — DONE (23aa11e)
- rotate-session.sh Next Session Task: DONE in S1a

## 4. session-protocol shutdown step 1 + Check 17 severity (inbox line 75)
- [x] config-check.sh Check 17: severity-differentiated tags — DONE (b191369)
- [x] clean-pending-files.sh: backward-compat wrapper — N/A (agent-fleet has full impl, cfg has wrapper)
- session-shutdown.md step 1 addendum: DONE in S1a
- manage-pending.sh + test suite: DONE in S1a
- config-auto-sync.sh Phase 0.6: DONE in S1a

## 5. token optimization: on-demand loading (inbox line 77)
- [x] CLAUDE.md step 1: skip full inbox read when hook already injected — DONE (23aa11e)
- [x] config-check.sh Check 27: afleet mandatory warning — DONE (b191369)
- session-protocol.md split + session-shutdown.md: DONE in S1a
- CLAUDE.md conditional triggers (shutdown, NAS, konsole): DONE in S1a

## 6. CLAUDE.md rule audit tightening (inbox line 81)
- [x] Co-Authored-By rules made model-agnostic — DONE (23aa11e)
- [x] Fixed Agent → Task in plan mode workaround — DONE (23aa11e)
- [x] Removed redundant Step 8 — replaced with populate session-context (23aa11e)
- [x] Tightened verbose rules — DONE (23aa11e)
- [x] Resolved stale TODO — drafts/ convention consolidated (80eb14d)
- setup/config vs global separation rule: DONE in S1a
- context budget awareness rule: DONE in S1a

## 7. ask-passphrase.sh + sync.sh collect guard for project rules (inbox line 88)
- [x] setup/scripts/ask-passphrase.sh — DONE (226ee37)
- [x] sync.sh: timestamp guard for project-specific rules collection loop — DONE (5b99cf7)
- [x] vault-ops.md + age-encryption.md: path references — VERIFIED generic (placeholder/relative paths, no changes needed)

## 8. cfg session 2026-03-12 outputs (inbox line 9)
- [x] setup/scripts/fleet-issue.sh + test — DONE, privacy scrubbed (226ee37)
- [x] setup/scripts/session-lock.sh + test — DONE (226ee37)
- [x] global/knowledge/fleet-issue-protocol.md — DONE (7a27305)
- [x] global/CLAUDE.md — fleet-issue trigger + vault-ops trigger — DONE (22b7a1b)
- [x] global/hooks/config-check.sh — symlink validation, severity tags, etc — DONE (b191369)
- [x] setup/scripts/afleet.sh — banner + pre-pull + AFLEET_LAUNCHED — DONE (226ee37)

## Bonus: New cfg rules propagated
- [x] Session leftovers → handover rule — DONE (80eb14d)
- [x] New backlog entries need user priority review — DONE (80eb14d)
- [x] User actions go LAST rule — DONE (80eb14d)

## Status: FULLY COMPLETE
All items resolved. vault-ops.md/age-encryption.md paths verified — already generic in template.
