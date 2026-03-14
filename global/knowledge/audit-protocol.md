# Audit Protocol

**Trigger:** User requests audit, cross-machine review, "check your work", or any situation where trust in prior session output needs verification. Also: self-initiated when resuming after unsupervised multi-session work.

**Research basis:** `docs/audit-framework-research.md` — synthesized from ISO 9001, CMMI, Fagan inspection, OWASP ASVS, PTES, OSSTMM, NIST 800-53, SOX, IIA, SRE postmortems, chaos engineering, and formal verification.

## Audit Pattern Catalog

Unified catalog of reusable audit playbooks. Each pattern defines scope, method, agents, and duration. Choose based on trigger and risk. Patterns can be combined.

**Default trigger mapping:**

| Trigger | Pattern |
|---------|---------|
| `lrn`, "check your work", post-routine-session | **P1: Quick Scan** |
| Resuming after 3+ sessions, post-deployment | **P2: Standard Audit** |
| Post-incident, post-propagation, user-requested deep audit | **P3: Deep Audit** |
| Major structural changes, fleet-wide health check, cross-project issues | **P4: Deep Multi-Agent Fleet Self-Audit** |

---

### P1: Quick Scan

**Purpose:** Fast automated health check. Catches regressions and drift without deep investigation. The "smoke test" of audits — if this passes, things are probably fine. Not suitable for post-incident analysis or cross-project consistency checks.

| Field | Value |
|-------|-------|
| Agents | 1 (current session) |
| Scope | Single project, automated checks only |
| Method | Run invariants (INV-1 through INV-9), test suite, `sync.sh status`, git log consistency |
| Duration | ~15 min |
| Output | Pass/fail summary in session-context.md |
| Triggers | `lrn`, post-routine-session, daily check, low-risk trigger, resuming after 1 unsupervised session |

---

### P2: Standard Audit

**Purpose:** Manual review of session claims and cross-repo consistency. Catches false "tests green" claims, propagation misses, and drift that automated checks miss. The workhorse audit — most triggers land here. Not suitable for full root cause analysis or fleet-wide structural reviews.

| Field | Value |
|-------|-------|
| Agents | 1 (current session) |
| Scope | Single project + its propagation targets |
| Method | P1 checks + manual review of session claims, cross-machine comparison, propagation verification |
| Duration | 1-2 hours |
| Output | Evidence file + audit log entry |
| Triggers | Post-multi-session work, post-deployment, moderate-risk trigger, resuming after 3+ sessions |

---

### P3: Deep Audit

**Purpose:** Full investigation with independent reproduction and root cause analysis. Used when something went wrong or when trust in prior work is low. Includes sibling search (if X broke, what similar things might be broken?) and meta-audit of the audit itself. Expensive but thorough. Not suitable for routine checks — overkill for "did the deploy work?"

| Field | Value |
|-------|-------|
| Agents | 1-2 (current session + optional verification subagent) |
| Scope | Single project, full depth |
| Method | P2 checks + independent reproduction, full root cause analysis, sibling search, coverage gap analysis |
| Duration | Half-day+ |
| Output | Evidence file + audit log + corrective actions |
| Triggers | Post-unsupervised multi-day work, post-incident, high-risk trigger, user-requested |

---

### P4: Deep Multi-Agent Fleet Self-Audit

**Purpose:** Full-fleet infrastructure health check across both the private config repo and public template, using parallel Opus subagents. Catches cross-project divergence, propagation chain failures, manifest staleness, personal data leaks in templates, and system-wide blind spots that single-project audits miss. The most thorough pattern — run it after major structural changes or periodically (monthly). Not suitable for quick checks or single-project issues.

| Field | Value |
|-------|-------|
| Agents | 4 Opus subagents in 3 phases |
| Scope | All fleet repos + deployed state + broader system (DMS, AFD, vault, MCP) |
| Duration | Half-day+ (agents run ~8 min each, analysis adds time) |
| Output | Pending file with consolidated findings and multi-session fix plan |
| Triggers | Major structural changes, periodic fleet health, cross-project issues found in P2/P3 |

**Full orchestration guide:** `knowledge/audit-pattern-fleet.md` (loaded on use, not at audit trigger).

---

## Three Lines of Defense

Our system operates on three layers. The audit protocol (Steps 0-8) is the third line. Understanding all three prevents gaps.

| Line | What | Examples | Cadence |
|------|------|----------|---------|
| **1st — Operational Controls** | Session-level guardrails | TDD, pre-commit hooks, CLAUDE.md rules, propagation checks, `sync.sh check` at shutdown | Every session |
| **2nd — Continuous Monitoring** | Automated oversight independent of sessions | SessionStart hook checks, daily drift detection, `sync.sh status`, dashboard staleness warnings | Daily / automatic |
| **3rd — Independent Audit** | This protocol (Steps 0-8) | Full manual audit, cross-machine verification, root cause analysis, evidence files | On trigger / periodic |

**Key insight:** If the 2nd line is strong, the 3rd line can be lighter. If the 2nd line is weak, more frequent and deeper 3rd-line audits are needed.

## System Invariants

Properties that must ALWAYS be true. Check these mechanically before/during any audit.

| ID | Invariant | Check Method |
|----|-----------|-------------|
| INV-1 | All test suites pass on the current machine | `bash setup/tests/run.sh` |
| INV-2 | `sync.sh check` returns clean (template, hooks, project rules) | `bash sync.sh check` |
| INV-3 | No plaintext secrets outside vault | `grep -rn` for known token patterns |
| INV-4 | Every file in `global/` has a deployed counterpart | Compare `global/` listing with `~/.claude/` |
| INV-5 | Session context was properly rotated (not stale) | `session-context.md` has empty/template Session Goal |
| INV-6 | `registry.md` lists every active project | Cross-reference `~/` directories with registry |
| INV-7 | No orphaned inbox tasks older than 7 days | Check `inbox.md` timestamps |
| INV-8 | Manifest hashes are current | `bash sync.sh stamp` produces no diff |
| INV-9 | All symlinks in `~/.claude/` point to valid targets | `find ~/.claude -type l ! -exec test -e {} \; -print` |

**Usage:** At audit start (Step 0a), run all invariants. Violations are immediate findings. If all pass, consider reducing audit depth one level.

## The 8-Step Self-Audit Workflow

### 0. Initial Analysis

**Entry criteria:** Audit trigger identified, depth level selected.
**Exit criteria:** Complete scope defined, all artifacts gathered and persisted, materiality assessed.

Scope the blast radius before any checking begins.

**0a. Steady State Check** — Run all System Invariants first. If steady state holds, consider L1 depth. If broken, that's your first finding — proceed with at least L2.

**0b. Materiality Assessment** — Not everything warrants equal scrutiny.
- **Material:** CLAUDE.md rules, sync.sh, hooks, test logic, secret handling, cross-machine configs, propagation targets
- **Immaterial:** Session log wording, comment formatting, doc typos with no behavioral impact
- Audit effort should be proportional to materiality. Skip immaterial areas unless they exhibit patterns.

a. **Identify time boundaries** — which date range, which sessions?
   - **Trust calibration per source:** Unsupervised sessions have lower trust than reviewed ones. Sessions on machines with different configs (git defaultBranch, PATH, tool versions) can produce different results from identical code. Rate each source's reliability before interpreting its claims.
b. **Identify machines** — which devices were active? (Read session-log.md, git logs across repos)
c. **Identify repos and projects** — which repos were touched? Check registry.md.
d. **Identify actors** — which sessions on which machines? VPS-via-mobile vs VPS-direct vs office vs mobile app have different trust levels.
e. **Gather all artifacts** — commits, session logs, outbox items, inbox tasks, emails sent, deployed configs. Persist immediately.
f. **Check against policies** — for each artifact, verify against CLAUDE.md rules, dev rules, TDD, propagation rules, template sync rules, commit conventions.
g. **Check against consistency** — cross-reference claims vs reality ("all tests green" is a hypothesis, not a fact). Also check for contradictions: do decisions.md entries contradict CLAUDE.md rules? Do research docs contradict final decisions? Do different sessions' claims contradict each other? Consistency = both "matches reality" AND "contradiction-free across all artifacts."
h. **Check correctness** — syntax, logic, edge cases, security, compatibility across machines.
i. **Check by testing** — run full test suite. Audit the tests themselves (false positives, fixture quality, coverage).
j. **Check coverage gaps** — what WASN'T checked? Widen search around each finding. If X is broken, what similar things might be broken?
k. **Persist** — document everything, write evidence file, prepare for meta-audit.

### 1. Verify Findings Independently

**Entry criteria:** Step 0 complete — all artifacts gathered, scope defined, materiality assessed.
**Exit criteria:** Every finding reproduced with evidence, severity and category assigned.

a. **Reproduce each finding** — don't trust audit agents. Re-read actual files, re-run actual commands.
b. **Confirm exact location** — file path, line number, commit hash.
c. **Classify severity** — CRITICAL / HIGH / MEDIUM / LOW with evidence.
d. **Tag by category** — code bug, test gap, false claim, propagation failure, doc error, process gap, cross-machine inconsistency.

### 2. Check Missed Spots (Widen Search)

**Entry criteria:** All initial findings independently verified (Step 1 complete).
**Exit criteria:** Sibling search complete for every finding, confidence map documented.

a. **Sibling search** — for each finding, check what SIMILAR issues might exist. If upgrade.sh hardcodes `main`, grep for `main` in all scripts.
b. **Unaudited areas** — which repos/files/machines were NOT checked? Why?
c. **Unknown unknowns** — what error categories weren't in the audit plan?
d. **Confidence map** — rate confidence for each finding AND each "clean" area. "No issues found" ≠ "no issues exist."

### 3. Root Cause Analysis

**Entry criteria:** Finding list is complete (Steps 1-2 done). No new findings expected.
**Exit criteria:** Every finding has an identified root cause and blast radius assessment.

a. **Identify root cause** — not the symptom. Why did X happen?
b. **Trace the failure chain** — which commit, which session, which machine introduced it?
c. **Identify the missing check** — what rule/test/process would have prevented this?
d. **Assess blast radius** — what else could be wrong because of the same root cause?

### 4. Proof of Correctness for False Positives

**Entry criteria:** Root cause analysis complete (Step 3).
**Exit criteria:** Every uncertain finding resolved with evidence. No "probably fine."

(Also applies to "confirmed clean" areas — absence of evidence is not evidence of absence.)
a. **For each "UNCERTAIN" or "POSSIBLE NON-ISSUE" finding** — provide evidence one way or the other.
b. **No "probably fine"** — either it's a real issue with evidence, or it's confirmed clean with evidence.
c. **Document the proof** — next auditor must be able to verify without re-investigating.

### 5. Everything Must Be Accounted For

**Entry criteria:** Steps 1-4 complete. All findings classified with evidence.
**Exit criteria:** Reconciliation table complete — zero unresolved items.

a. **Reconcile finding list** — every item from Step 0 must have a status: verified issue, confirmed false positive, or explicitly deferred with reason.
b. **No orphaned findings** — nothing left as "unclear" or "needs investigation."
c. **Cross-reference against original claims** — every claim from prior sessions ("tests green", "deployed", "done") must be individually confirmed or refuted.

### 6. Proper Planning for Each Fix

**Entry criteria:** Finding list finalized and fully classified (Step 5).
**Exit criteria:** Every verified issue has a concrete fix plan with dependencies mapped.

a. **Write concrete fix plan** — exact files, exact changes, exact test to prove it's fixed.
b. **Identify dependencies** — which fixes must happen before others?
c. **Assess risk** — could the fix break something else? What's the rollback?
d. **Estimate scope** — single-line fix vs multi-file refactor.

### 7. Cross-Check Everything

**Entry criteria:** All fix plans written (Step 6).
**Exit criteria:** No conflicts between plans, completeness verified, peer review done if applicable.

a. **Review all fix plans together** — do any conflict?
b. **Check cascading effects** — if we fix sync.sh, does that invalidate the template comparison?
c. **Verify completeness** — every finding must have a fix plan or documented "not an issue + proof."
d. **Peer review** — if possible, use a separate agent to review the fix plans.

### 8. Execute Fixes

**Entry criteria:** Cross-check complete (Step 7), user approved fix plan.
**Exit criteria:** All tests pass, sync clean, propagation complete, audit log updated.

a. **Fix in dependency order** — blocked fixes wait.
b. **Test after EACH fix** — not in bulk.
c. **Full suite after all fixes** — every test must pass. No "known failures."
d. **Propagate** — template, hooks, mobile, all chains from dependency-map.md.
e. **Final `sync.sh check`** — must be clean.
f. **Update audit log** — record what was fixed and how.
g. **Verify prior corrective actions** — check if fixes from previous audits are still effective. If a prior fix was "add a test," verify the test still runs and catches the original defect.

## Audit Log

Maintained at: `docs/audit-log.md`. Append-only. One entry per audit.

Entry format:
```
### YYYY-MM-DD — [scope description]
- **Trigger:** [why this audit happened]
- **Depth:** L1 / L2 / L3
- **Scope:** [machines, repos, timespan]
- **Agents used:** [count and types]
- **Invariants at start:** [N/9 passing — list any failures]
- **Findings:** [X critical, Y high, Z medium, W low]
- **Key issues:** [1-3 most significant]
- **False claims caught:** [any "tests green" that weren't, etc.]
- **Near-misses:** [things that almost went wrong but didn't — leading indicators]
- **Gaps identified:** [what wasn't checked / what was missed]
- **Prior corrective actions verified:** [which prior fixes were re-tested, results]
- **Meta-observations:** [patterns, recurring issues, process improvements]
- **Evidence file:** `docs/audit-YYYY-MM-DD.md`
```

**Quantitative metrics** (track across audits for trend analysis):
- Findings count by severity
- Claim accuracy rate (verified claims / total claims)
- Time from defect introduction to detection (commits or days)
- Invariant pass rate at audit start
- Corrective action effectiveness rate

## Audit Continuity Rule — HARD CONSTRAINT

**During an active audit (from trigger through Step 8 completion), NOTHING from any session may be lost or dropped.** This means:
- Session rotation does NOT truncate audit findings. The full meta-plan, all findings, all evidence must survive into session-history.md and session-log.md.
- If context runs low mid-audit, persist ALL conversation artifacts to files BEFORE the session ends. Agent outputs, intermediate analysis, user corrections, evolving plans — write them to `docs/audit-YYYY-MM-DD.md` or session-context.md.
- The next session must be able to continue the audit with ZERO information loss. "Read session-context.md" is insufficient if the session-context was rotated to a summary. The evidence file and audit log are the continuity mechanism.
- This rule applies to ALL sessions during an audit, not just the first. An audit may span multiple sessions. Each session must leave the next one with everything it needs.
- Corollary: prefer over-persisting to under-persisting during audits. A few KB of redundant documentation costs nothing. Lost findings cost an entire re-investigation.

## Meta-Audit Protocol

Periodic review of audit findings across time. Trigger: monthly, or when user requests.

1. Read all entries in `docs/audit-log.md`
2. Pattern detection: which issue categories recur? Which machines produce more issues?
3. Root cause clustering: group recurring issues by root cause
4. Protocol improvement: what should be added to this protocol based on what was missed?
5. Trust calibration: which types of session claims can be trusted vs need mandatory verification?
6. **Trend analysis:** Compare quantitative metrics across audits. Are findings declining? Is claim accuracy improving? Are corrective actions sticking?
7. **Control testing (fault injection):** Periodically verify that 1st/2nd line controls actually fire:
   - Introduce a known rule violation → does the next session catch it?
   - Deploy a stale config → does `sync.sh check` detect drift?
   - Claim "tests green" when they aren't → does the next audit catch the false claim?
   If a control doesn't fire, that's a critical finding — the guardrail is silently broken.
8. **Maturity self-rating:** Annually rate each audit capability on a 1-5 scale (CMMI-inspired). Track progress.

## Self-Audit Triggers

Run a self-audit (even without user request) when:
- Resuming after 3+ unsupervised sessions
- After multi-machine work spanning a full day
- After any session that claimed "all tests green" without showing test output
- After any session that modified propagation targets (template, hooks, mobile)
- After any session that sent emails or posted to external services

**Suggested depth per trigger:**
| Trigger | Default Depth |
|---------|---------------|
| Resuming after 1 unsupervised session | L1 |
| Resuming after 3+ unsupervised sessions | L2 |
| User says "audit" / "check your work" | L2 |
| Multi-machine work spanning a full day | L2 |
| Post-incident or post-propagation changes | L3 |
| Session claimed "tests green" without output | L2 |
| Emails sent or external services used | L2 |

## Adversarial Mindset

Adopted from property-based testing: frame audits as **"try to disprove"** rather than "try to confirm."

- Don't verify that things work — try to find where they DON'T.
- For each session claim, ask: "What would have to be true for this claim to be false?"
- For each "clean" area, ask: "What defect could exist here that wouldn't be caught by our current checks?"
- Assume the most recent session's claims are hypotheses, not facts.

## Lessons Learned — Inaugural Audit (2026-03-03)

1. **"All tests green" is a hypothesis.** VPS claimed 22/22 and 32/32. Deck found 4 failures + 3 false positives. Root cause TBD (likely cross-machine git config).
2. **Mobile app sessions are invisible without logging.** Added session-log.md to mobile CLAUDE.md.
3. **Audit agents can be wrong.** Their findings are hypotheses needing independent verification.
4. **Scoping is the most important step.** Initial audit missed mobile app session entirely.
5. **Widening search catches siblings.** Check each file in isolation misses systemic issues.
6. **Persist evidence immediately.** `/tmp/` agent outputs would be lost on reboot.
7. **Step 0 substeps (policy, consistency, correctness, testing, coverage) are NOT optional.** First audit conflated them and missed policy violations.
8. **`((var++))` with `set -e` is a bash trap.** Post-increment returns the original value — `((0++))` evaluates to 0, which is falsy, triggering `set -e` exit. Use `var=$((var + 1))` instead. (Found during CFG-32 implementation.)
