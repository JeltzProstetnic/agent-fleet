# Known Faulty Rule Patterns

Catalog of rule formulations that reliably fail. When auditing rules (in CLAUDE.md, knowledge files, or project configs), flag any rule matching these patterns.

## Pattern 1: Deferred Verification Instead of Atomic Action

**Symptom:** Rule says "verify X matches Y before writing summary" or "check canonical state at shutdown."
**Why it fails:** By verification time, the action is long past. The check depends on remembering to verify -- which fails under cognitive load.
**Fix:** Make tracking atomic with the action. "After sending email, update contacts.md IMMEDIATELY" not "verify contacts.md matches at shutdown."
**Example:** "Narrative must match canonical state" failed to trigger outreach tracking (Session 163).

## Pattern 2: General Principle Instead of Action-Specific Trigger

**Symptom:** Rule says "always do X when Y" where Y is a broad category (e.g., "when discovering information", "when the user shares context").
**Why it fails:** Broad triggers don't fire on specific actions. "Discovery" isn't a discrete event -- it's continuous. Nothing specific triggers the rule.
**Fix:** Replace with concrete action triggers: "After running a web search that reveals a new tool capability -> update fleet-capabilities.md."
**Example:** "Discovery -> ingest" is a principle. No specific action fires it.

## Pattern 3: Pre-Step That Competes With the Main Action

**Symptom:** Rule says "before doing X, first check Y" where X is the salient, motivated action and Y is an auxiliary check.
**Why it fails:** When starting X, attention is on X's content, not on remembering to do Y first. The pre-step is cognitively invisible.
**Fix:** Bundle pre-steps into a named workflow with numbered steps. "Outreach email workflow: step 1 check contacts, step 2 check log, step 3 draft" -- not scattered independent rules.
**Example:** "Check communications log before drafting" exists as a standalone rule, separate from the drafting workflow.

## Pattern 4: Principle Buried in a Wall of Rules

**Symptom:** Important behavioral rule is item #27 in a 40-rule list, with no structural distinction from adjacent rules.
**Why it fails:** Scanning a flat list of 40 rules for the relevant one requires perfect recall. Rules compete for attention equally.
**Fix:** Group rules into workflows at the point of action (Communication Rules, Submission Rules, etc.) rather than one flat Development Rules list. Critical rules should be in the section where the action happens.

## Pattern 5: "Rule Exists -- I'll Follow It Better"

**Symptom:** Audit concludes "the rule already exists, I just need to follow it" or "acknowledged, no new rule needed."
**Why it fails:** If the rule existed and was violated, the rule is structurally inadequate. "Follow it better" is not a systemic fix -- it's the software equivalent of "we'll be more careful next time." The violation happened BECAUSE the rule's structure (wording, location, loading, enforcement tier) failed to prevent it -- or because the root cause lies elsewhere entirely.
**Fix:** Mandatory root cause analysis with an open mind: Why did the rule fail to fire? Options include but are not limited to:
  (a) Rule needs rewriting (unclear, too generic, missing the specific failure mode)
  (b) Rule needs different loading (read at startup but needed mid-session -> move to workflow or knowledge file loaded at point of action)
  (c) Rule needs different enforcement tier (behavioral rule -> hook/script/automation)
  (d) Rule needs bundling into a workflow (standalone rule lost in a list -> numbered steps in a named procedure)
  (e) Rule has a competing rule that overrides it (urgency vs. consent)
  (f) The issue is not with the rule at all -- a different process, assumption, tool behavior, or environmental factor caused the violation. The rule may be fine; the problem may be upstream, downstream, or orthogonal.
"Rule exists" is the START of root cause analysis, never the conclusion.

## Pattern 6: Static Config Test Instead of Behavioral Test

**Symptom:** Tests read config files and check key=value, but never verify the config affects running behavior.
**Why it fails:** Config can be correct on disk but not applied at runtime -- wrong file targeted, stale session, config inheritance overridden, profile not loaded. Test passes, bug persists.
**Fix:** Separate static tests (config linting -- low value, cheap) from behavioral tests (exercise the system, observe the effect -- high value, required). Both needed; statics alone are insufficient for environmental fixes. Evidence: Session 19 wrote 8 passing static tests for a scrollback fix that targeted the wrong Konsole profile.

## Pattern 7: False Verification via Skip Clauses

**Symptom:** Test skips when the feature it's supposed to test isn't available (e.g., "if Konsole isn't running, skip scrollback test").
**Why it fails:** If the test exists to verify a Konsole fix, then "Konsole not running" means the test is uncovered, not gracefully degraded. The skip clause turns a mandatory check into an optional one.
**Fix:** Distinguish optional-feature skips (legitimate) from core-failure-mode skips (bugs). If the test covers the exact scenario the fix targets, it must fail hard when that scenario can't be tested -- not silently skip.

## Pattern 8: Decorative Justification in Rules

**Symptom:** Rule ends with a motivational explanation like "The cost of X is far less than Y" or "This prevents confusion" or "This is important because..."
**Why it fails:** It doesn't fail operationally -- it wastes tokens and dilutes signal. Every decorative sentence competes for attention with the actual instruction. Rules should be imperatives, not essays. If the "why" isn't load-bearing (i.e., needed to judge edge cases), it's noise.
**Fix:** Strip justifications that don't inform edge-case judgment. Keep `**Why:**` lines only when the reason changes how you'd apply the rule in ambiguous situations. Delete "this is better because obvious thing is obvious."

## Pattern 9: Over-Engineered Rule Text

**Symptom:** Proposed rule has branching logic ("if X do A, else B"), numbered options, preemptive edge cases, or explanatory scaffolding around a single imperative.
**Why it fails:** Branching creates decision points that compete with the action. The user's correction pattern is always: collapse to one imperative sentence.
**Fix:** Flat imperatives. One action, one sentence. If branching seems needed, it's two rules or wrong scope. Match the style of existing rules in the target file.

## Pattern 10: Prose Rule vs Point-of-Action Vendor Instruction

**Symptom:** A rule forbids a behaviour that a tool's own description or system instruction invites at the point of action.
**Why it fails:** The vendor text is present on every turn, right where the action happens, and cannot be edited or outranked; a prose rule loaded elsewhere loses regardless of wording, placement or loading — unlike Patterns 1-9, no rewrite fixes it.
**Fix:** Enforce with a `PreToolUse` block (or remove/disable the instruction or tool); never rely on a prose rule as the control.
**Example:** A tool description saying "Publishing proactively is fine for your own work-product" — no CLAUDE.md rule could stop the publish it invited.

## Pattern 11: A Green Test Proves the Fixture, Not the World

**Symptom:** A check parses a documented convention (file header, hook payload, log format) and every test feeds it a hand-written fixture shaped like the author's belief.
**Why it fails:** The test verifies the parser against the input it was written for; if the belief is wrong the check and its tests agree and pass while the feature never fires.
**Fix:** At least one test must exercise a real artifact — a file from the repo or input captured from the live producer — not only a hand-written fixture.
**Example:** A fixture wrote `Tracked-by:` bare while real files use `<!-- Tracked-by: -->`, and stayed green for two months; a hook read `tool_output.stdout` and its tests fed the same invented shape, while Claude Code sends `tool_response`.

## Pattern 12: Executable Code in Rule Text

**Symptom:** A rule tells the agent to run a literal command — shell syntax, globs, brace expansion, home-relative paths — as a step of the behaviour it requires.
**Why it fails:** The command is platform-dependent and goes stale silently: it breaks on another OS or shell, drifts from the scripts it duplicates, and "match the target file's style" copies it into the next rule.
**Fix:** State the intent and end state; put any needed command into a tested script and name the script, or into a mechanism. A command that is itself the subject of a rule (e.g. which form of `git commit` to use) is not a step and may stay.
**Example:** A draft "Cross-project fleet changes reach every consumer" rule embedded `grep -rlsI --exclude-dir={.git,worktrees} … ~/*/CLAUDE.md …`, copied in style from the rule it replaced; the owner's verdict: "hard coded platform dependent code within rules surely not".
