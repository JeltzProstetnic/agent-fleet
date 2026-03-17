# Learn Protocol (`lrn` / `learn`)

Self-audit command. Designed for low-context situations — uses subagents with their own context windows for analysis.

## Execution

**Adaptive, not fixed.** Assess the situation first, then launch 1-3 parallel Explore subagents tailored to what's relevant. Don't run all 3 categories if only 1-2 apply.

### Step 1 — Triage (inline, no subagent)

Before launching subagents, quickly assess:
- **What went wrong?** Rule violation, missed info, process gap, architecture issue?
- **What's the user's tone?** Frustrated (→ root cause + fix), curious (→ deeper analysis), directive (→ just do it)?
- **Which audit categories are relevant?**

### Step 2 — Pick relevant agents

| Category | When to include | Skip when... |
|----------|----------------|-------------|
| **Rule Compliance** | Something broke, a protocol was violated, user says "learn from this" | Issue is purely architectural or forward-looking |
| **Knowledge Capture** | User shared or corrected anything that should persist in the knowledge base (especially people/contacts) | Session introduced no durable knowledge worth capturing |
| **Process/Architecture** | Repeated pattern, automation opportunity, workflow gap, scaling issue | One-off mistake with obvious inline fix |

Launch only the relevant ones. 1 agent is fine if the issue is clear. All 3 only if the situation is genuinely multi-faceted.

### Agent Templates

#### Rule Compliance Agent
Prompt the subagent with:
- Read `~/.claude/CLAUDE.md` (global rules), the project's `CLAUDE.md`, and `~/.claude/foundation/session-protocol.md`
- Read `session-context.md` in the current project
- Read `git log --oneline -10` output for the current project
- For each issue, mistake, or failure identified this session, analyze through the rule system:
  1. **Was a rule violated?** → Which rule, what was the evidence, why did compliance fail?
  2. **Was a rule present but insufficient?** → Rule exists but didn't prevent the issue — needs strengthening or different enforcement tier (behavioral → automated)?
  **GATE CHECK — if your analysis reaches "rule exists, just follow it": STOP. This conclusion is always wrong. Re-enter at step 2 and investigate WHY the rule failed structurally, or whether the root cause lies elsewhere entirely. See Known Faulty Rule Patterns → Pattern 5.**
  3. **Is a new rule justified?** → No existing rule covers this — does the pattern warrant one, or is it a one-off?
  4. **Is the issue rule-irrelevant?** → Not everything is a rule problem. Architecture gap, missing automation, stale data, human error with no systemic fix.
  These are branching points for root cause analysis, not a checklist to scan.
- Common patterns to watch for (non-exhaustive): skipped startup steps, rules written without user consent, `cd &&` compounds, new files for daily state, stale session-context.md, committed secrets, skipped TDD, cross-project boundary violations.
- Report each finding with: rule text (or gap), evidence, root cause analysis, suggested fix

#### Knowledge Capture Agent
Prompt the subagent with:
- Read `session-context.md` in the current project
- Read machine file (`~/.claude/machines/<machine>.md`) for the current machine
- Read `~/.claude/domains/life-management/relationships.md` (people KB)
- Read `~/.claude/domains/life-management/family.md`
- Check: Did the user share information this session that isn't captured?
  - New hardware/equipment details → machine files
  - New people/contacts → relationships.md
  - New preferences/habits → appropriate KB file
  - Personal/family context → family.md
  - Decisions made → docs/decisions.md
- Also check: Is anything in the KB files **contradicted, incomplete, or outdated** given session activity?
- **Extend-over-create rule:** When a finding maps to an existing file, propose extending/correcting that file — don't create a new file or rule. Corrections to existing knowledge are the highest-value, lowest-cost fix.
- Report each gap with: what info, where it should go (existing file preferred), proposed content

#### Process/Architecture Agent
Prompt the subagent with:
- Read `session-context.md` and `session-history.md` in the current project
- Read `backlog.md` in the current project
- Read `docs/decisions.md` if it exists
- Focus on the specific pattern/issue identified in triage
- Check: Are there systemic improvements needed?
  - Repeated manual steps that could be automated (hooks, scripts)
  - Recurring mistakes that need documentation or guardrails
  - Missing classification or metadata (e.g., task recurrence types)
  - Processes that could be streamlined
  - **Existing knowledge that is incomplete, outdated, or contradicted by session evidence**
- Report each finding with: pattern observed, suggested fix using the **least-cost tier**:
  1. Hook/script (0 tokens) — if automatable
  2. **Extend/correct existing knowledge file** (0 tokens unless triggered) — ALWAYS preferred over creating new files. Check `~/.claude/knowledge/`, `~/.claude/reference/`, `~/.claude/domains/`, machine files, and project knowledge for existing coverage first.
  3. New knowledge file (0 tokens unless triggered) — only if no existing file covers the topic
  4. Backlog item (0 tokens, read on demand) — one-time fixes
  5. Project CLAUDE.md rule (tokens per project session) — project-specific behavioral invariants
  6. Global CLAUDE.md rule (tokens EVERY session) — only cross-project behavioral rules that can't live anywhere else
  - **Bias check — MANDATORY for every finding:**
    1. Does an existing file already cover this topic? → **Extend it**, don't create a new file or rule.
    2. Could this be a hook or script? → Automate it (0 tokens).
    3. Is this a one-time fix? → Backlog item, not a permanent rule.
    4. Does this need to run every session? → Only then consider a CLAUDE.md rule.
    5. Rules are the **most expensive** fix. Knowledge files are cheap. Extending existing files is cheapest. Default DOWN the hierarchy, not up.

### Pattern 5: "Rule Exists — I'll Follow It Better"
**Symptom:** Audit concludes "the rule already exists, I just need to follow it" or "acknowledged, no new rule needed."
**Why it fails:** If the rule existed and was violated, the rule is structurally inadequate. "Follow it better" is not a systemic fix — it's the software equivalent of "we'll be more careful next time." The violation happened BECAUSE the rule's structure (wording, location, loading, enforcement tier) failed to prevent it — or because the root cause lies elsewhere entirely.
**Fix:** Mandatory root cause analysis with an open mind: Why did the rule fail to fire? Options include but are not limited to:
  (a) Rule needs rewriting (unclear, too generic, missing the specific failure mode)
  (b) Rule needs different loading (read at startup but needed mid-session → move to workflow or knowledge file loaded at point of action)
  (c) Rule needs different enforcement tier (behavioral rule → hook/script/automation)
  (d) Rule needs bundling into a workflow (standalone rule lost in a list → numbered steps in a named procedure)
  (e) Rule has a competing rule that overrides it (urgency vs. consent)
  (f) The issue is not with the rule at all — a different process, assumption, tool behavior, or environmental factor caused the violation. The rule may be fine; the problem may be upstream, downstream, or orthogonal.
"Rule exists" is the START of root cause analysis, never the conclusion.

## Presenting Results

After subagents return:

1. **Consolidate** — group findings by type
2. **Prioritize** — critical fixes first, then high-value improvements
3. **Present** — concise report to user with proposed actions
4. **Approve** — rule changes and KB updates require explicit user approval before persisting
5. **Execute** — after approval, make the changes (edit files, add backlog items)

## Context Efficiency

- **Subagents over inline analysis** — each gets a fresh context window
- **Explore agents** — read-only, can't accidentally modify files
- **Parallel execution** — all selected agents run simultaneously
- **File-based evidence** — subagents read files, not conversation history (which may be compressed)
- **Session-context.md as anchor** — this file should be up-to-date before `lrn` runs; update it first if needed
- **Adaptive count** — 1 agent for clear issues, 2-3 for multi-faceted situations. Don't waste tokens on categories that obviously don't apply.

## Context Pressure Rule — MANDATORY

**When `lrn` runs late in a session (especially as part of `lrnd`), always write findings directly to `docs/pending-lrn-audit-YYYY-MM-DD.md` instead of holding them in conversation context for inline presentation.** Subagent results returning into an already-consumed main context can trigger auto-compact, losing session state and disrupting subsequent shutdown steps.

Decision rule:
- **`lrnd` (lrn+end)**: ALWAYS write to file. The shutdown phase needs context headroom.
- **Standalone `lrn`**: Present inline if early in session. Write to file if context feels pressured (long session, many prior tool calls, approaching 50%+ usage).
- **File format**: `docs/pending-lrn-audit-YYYY-MM-DD.md` — action items for next session pickup via `next-session-task.md`.

## Execution Rule — MANDATORY

**Audit findings MUST be promoted to backlog items immediately** — not just written to pending files. The pending file is a detail reference; the backlog item is the action tracker. Without a backlog item, findings accumulate in `docs/pending-lrn-*.md` and never get executed (confirmed pattern: stale pending files with unpromoted findings).

Flow:
1. Write detailed findings to `docs/pending-lrn-audit-YYYY-MM-DD.md`
2. For EACH actionable finding, add a backlog item (P0-P2) to `backlog.md` referencing the pending file
3. Delete the pending file once ALL its findings have backlog items
4. Backlog items get executed in subsequent sessions with full context

**Night mode timing:** If `lrn` runs during night mode (weekday >= 17:00, weekend >= 20:00), write findings to file + create backlog items, but defer execution to next day mode session. Night mode audits should capture, not execute.
