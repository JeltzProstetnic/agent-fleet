Action: act

# Deployment Audit Follow-Up

Completed 2026-03-13 deployment disaster audit. Remaining work:

## Immediate (this session)

1. **Push 2 commits** on main (unpushed):
   - `340ac3a` — sync.sh inbox counter fix (closes GitHub #1)
   - `b47f7a4` — config-check.sh merge (6 checks from cfg, numbering resolved)

2. **IvoclarR-D-AIOrg in install.sh** — advisory from sanitization audit: `IvoclarR-D-AIOrg/agent-fleet` appears in clone detection code (line ~60). Public org, functional code. User decision: strip or keep.

## Next Session

3. **E2E test harness implementation** — plan at `tmp/e2e-test-plan.md` (28 test cases, TAP output). Ubuntu rootfs at `C:\WSL\ubuntu-24.04-base.tar.gz` (341MB). File structure: `setup/tests/e2e/`. Create `test-e2e-deploy.sh` orchestrator + phase scripts.

4. **CFG-101 remaining propagation** — Check 31 (session lock) is done. Still needed:
   - `global/knowledge/follower-mode.md` (3 lines)
   - `global/CLAUDE.md` conditional loading table entry (SESSION_LOCKED trigger)
   - `setup/scripts/afleet.sh` lock acquire logic
   - `setup/config/statusline-command.sh` heartbeat
   - `global/hooks/config-auto-sync.sh` lock release
   - `setup/tests/test-cfg101-server-lock.sh` (22 tests)
   - Strip AFD URL and personal hostnames

5. **vault-ops.md rule #6 + communication-policy.md** — persona email rules propagation from cfg

## Routed to cfg (via inbox)
- Commit sync.sh fix (already in cfg working tree)
- Adopt merged config-check.sh from template
- Investigate session lock false trigger across projects

## Artifacts produced this session
- `tmp/e2e-test-plan.md` — full E2E deployment test plan
- `tmp/config-check-divergence.md` — divergence analysis
- `tmp/sanitization-audit.md` — sanitization audit results
