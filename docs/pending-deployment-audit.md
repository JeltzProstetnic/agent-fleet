Action: act

# Deployment Audit Follow-Up (Updated 2026-03-13)

## Remaining

1. **Merge worktree-deployment-audit → main and push.** Branch has 3 merge commits (AFT-32/33, AFT-39/40/41, CFG-101 locking) on top of main. Clean merges, no conflicts expected. Then push to origin.

2. **IvoclarR-D-AIOrg in install.sh** — advisory from sanitization audit: `IvoclarR-D-AIOrg/agent-fleet` appears in clone detection code (line ~60). Public org, functional code. User decision: strip or keep.

3. **E2E test harness** — plan at `tmp/e2e-test-plan.md` (28 test cases, TAP output). Ubuntu rootfs at `C:\WSL\ubuntu-24.04-base.tar.gz`. AFT-39/40/41 created CI + integration tests + preflight, but full E2E (WSL rootfs deploy) is a separate, more comprehensive effort.

4. **4 pre-existing test failures** — test-config-check (2), test-gpi (2), test-install-setup (1), test-lrn-command (1). None from this session's work.

## Completed This Session
- [x] CFG-101 follower-mode propagation (follower-mode.md + CLAUDE.md trigger)
- [x] vault-ops.md rules 1-6 + communication-policy persona email rules
- [x] CFG-101 session locking (afleet.sh, statusline, auto-sync, afd-lib.sh, 22 tests)
- [x] AFT-32/33/39/40/41 — all 5 backlog items implemented with 51 new tests
