Action: act

# Remaining Template Propagation Items

S1a committed (777e606) covered the bulk files. These inbox items have remaining work:

## 1. learn-protocol.md fix hierarchy (inbox line 67)
- [ ] learn-protocol.md: 5-tier fix hierarchy with bias check
- [ ] CLAUDE.md conditional trigger for learn-protocol
- statusline-ops.md: DONE in S1a

## 2. drafts/ convention + fleet-capabilities + config-check (inbox line 68)
- [ ] CLAUDE.md: drafts/ rule extension, step 9 populate session-context
- [ ] project-setup.md: drafts/ dir in setup steps
- [ ] config-check.sh: .txt in Check 15, ACT_PENDING warning (Check 26), TMUX_ACTIVE (Check 26)
- [ ] fleet-capabilities.md: 3-tier grouping (strip personal Life OS packages for template)

## 3. collect guard + step 10 + Check 18 removal (inbox line 70)
- [ ] sync.sh collect: per-file timestamp guard for directory copies (CFG-128)
- [ ] CLAUDE.md step 10: human-readable startup/shutdown messages
- [ ] config-check.sh: Check 15 git-behind hint (CFG-130), Check 18 AFLEET_DASHBOARD removed
- [ ] Removed duplicate "plain-language" convention
- rotate-session.sh Next Session Task: DONE in S1a

## 4. session-protocol shutdown step 1 + Check 17 severity (inbox line 75)
- [ ] config-check.sh Check 17: severity-differentiated tags (STALE_ACT, STALE_DEFER, STALE_AWAIT)
- [ ] clean-pending-files.sh: backward-compat wrapper
- session-shutdown.md step 1 addendum: DONE in S1a
- manage-pending.sh + test suite: DONE in S1a
- config-auto-sync.sh Phase 0.6: DONE in S1a

## 5. token optimization: on-demand loading (inbox line 77)
- [ ] CLAUDE.md step 1: skip full inbox read when hook already injected INBOX TASKS
- [ ] config-check.sh Check 27: afleet mandatory warning
- session-protocol.md split + session-shutdown.md: DONE in S1a
- CLAUDE.md conditional triggers (shutdown, NAS, konsole): DONE in S1a

## 6. CLAUDE.md rule audit tightening (inbox line 81)
- [ ] Co-Authored-By rules made model-agnostic
- [ ] Fixed Agent → Task in plan mode workaround
- [ ] Removed redundant Step 8
- [ ] Tightened 4 verbose rules (~260 tokens/session saved)
- [ ] Resolved stale TODO comment (L184)
- setup/config vs global separation rule: DONE in S1a
- context budget awareness rule: DONE in S1a

## 7. ask-passphrase.sh + sync.sh collect guard for project rules (inbox line 88)
- [ ] setup/scripts/ask-passphrase.sh: cross-platform masked passphrase dialog
- [ ] sync.sh: timestamp guard for project-specific rules collection loop
- [ ] CLAUDE.md + vault-ops.md + age-encryption.md: path references updated

## 8. cfg session 2026-03-12 outputs (inbox line 9)
- [ ] setup/scripts/fleet-issue.sh + setup/tests/test-fleet-issue.sh — privacy scrub + dedup
- [ ] setup/scripts/session-lock.sh + setup/tests/test-session-lock.sh — PID-based session lock
- [x] global/knowledge/fleet-issue-protocol.md — DONE (7a27305)
- [x] global/CLAUDE.md — fleet-issue trigger + vault-ops trigger — DONE (22b7a1b)
- [ ] global/hooks/config-check.sh — symlink validation, .template-repo help, Check 17 severity
- [ ] setup/scripts/afleet.sh — custom banner with CC version

## Approach
For each item: diff the cfg-agent-fleet source against agent-fleet to see what's missing, copy/adapt, scrub personal data, test, commit. Work through items 1-8 in order.
