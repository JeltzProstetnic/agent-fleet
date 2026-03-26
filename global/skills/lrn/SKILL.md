---
name: lrn
description: Self-audit that prevents recurrence of session failures at lowest token cost. Triggers on "lrn", "learn from this", "make sure this doesn't happen again", "fix this permanently", "what went wrong", "self-audit".
---

# Mission

Prevent recurrence. Cheapest fix that works. End state: a hook (0 tokens), a one-sentence rule in the right file, or a backlog item -- approved by user.

# Modes

- `lrn` alone: full audit of current session.
- `lrn <words>`: apply audit lens to the topic that follows. Use finding format + gate check inline. Skip triage scaffolding.
- Night mode or context >60%: write findings to `docs/pending-lrn-audit-YYYY-MM-DD.md` (`Action: act`), create backlog items, defer execution.

# Execute

## 1. Triage (inline, no subagent)

The main agent witnessed the session. Do not delegate triage.

Review: scroll back, check `session-context.md`, last 10 git log entries. For each issue:
- What went wrong? Rule violation, missed info, process gap, stale knowledge, environmental?
- User tone? Frustrated (fix now), curious (analysis welcome), directive (just do it).
- Categories: rule compliance, knowledge capture, process/architecture. One category is fine. All three only when genuinely multi-faceted.

## 2. Classify each issue

For every issue: (a) rule violated -- why structurally? (b) rule present but insufficient? (c) new rule justified, or one-off? (d) not a rule problem -- architecture, automation, environment?

### GATE CHECK -- structural prominence

**"Rule exists, follow it better" is ALWAYS wrong. STOP.**

If analysis reaches this conclusion, re-enter classification. The rule failed structurally. Investigate:
- Wording unclear or too generic for this failure mode
- Loads at startup but needed mid-action -- move to point-of-action file
- Behavioral rule that should be automated (hook, script, pre-commit)
- Standalone rule lost in flat list -- bundle into named workflow
- Competing rule or priority overrode it
- Not the rule at all -- different process, tool, or environmental factor

"Rule exists" is the START of root cause analysis, never the conclusion.

## 3. Formulate findings

One block per finding. No prose.

```
FINDING: [one sentence]
ROOT CAUSE: [one sentence]
FIX: [exact rule text -- one sentence, flat imperative]
TARGET: [file:section]
TIER: [hook|extend-existing|new-knowledge|backlog|project-rule|global-rule]
```

### Rule-writing constraints

- One sentence. Flat imperative. No branching.
- Intent + end state, not procedure.
- Read the target file first. Match its style and density.
- General principle over case enumeration.
- No inline justification. Rationale in commit message or `decisions.md`.
- After user correction: adopt verbatim. Never re-expand.

Full research: `references/rule-writing-principles.md`.

### Tier hierarchy (use cheapest)

hook/script (0 tokens) > extend existing file (0 unless triggered) > new knowledge file (0 unless triggered) > backlog item (0, on demand) > project CLAUDE.md (per session) > global CLAUDE.md (EVERY session)

**Bias check per finding:** (1) Existing file covers this? Extend it. (2) Could be a hook? Automate. (3) One-time fix? Backlog, not rule. (4) Needs every session? Only then CLAUDE.md. Default DOWN the hierarchy.

## 4. Optional: Explore subagent

Launch ONE Explore subagent ONLY when the gate check identifies a rule that exists but failed structurally AND tracing requires 3+ files. If obvious from 1-2 files, read inline.

Subagent returns: one-sentence revised rule + target file + tier. Do NOT launch subagents for triage or knowledge capture. One subagent maximum.

## 5. Present and wait

Order findings by tier (cheapest first), then severity. Scan every FIX against Known Faulty Patterns before presenting. Then STOP. Wait for user approval.

**Approval handling:**
- "yes" / "go" -- execute all as presented.
- User edits a FIX -- use their version VERBATIM. Never re-expand.
- User rejects -- drop it. Do not re-propose.

## 6. Execute

Edit targets. Commit with rationale in message (never in rule text). Re-read each edit to verify style fit.

**Backlog promotion is mandatory.** Every actionable finding gets a backlog item immediately. Pending files are detail references; backlog items are action trackers.

# Gate check (redundant anchor for scanning)

See Step 2. "Rule exists, follow it better" = ALWAYS wrong. Investigate structural failure.

# Anti-patterns (names only)

Deferred Verification | General Principle | Competing Pre-Step | Buried Principle | "Follow It Better" | Static Config Test | False Skip | Decorative Justification | Over-Engineered Text

Full descriptions: `references/known-faulty-patterns.md`

# References

- `references/known-faulty-patterns.md` -- full pattern descriptions with examples
- `references/rule-writing-principles.md` -- research-backed rule formulation constraints
