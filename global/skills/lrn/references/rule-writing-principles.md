# Rule-Writing Principles

Synthesized from research on prompt engineering, military doctrine, aviation checklists, and observed agent behavior.

## The 5 Principles

1. **Intent, not procedure.** State purpose + end state. The executor chooses method.
2. **One assertion per rule.** "And" or "but" signals two rules. Split them.
3. **Fewer words = stronger compliance.** Every word dilutes signal. Budget: one sentence.
4. **General over specific.** One principle outperforms ten enumerated cases.
5. **Never justify inline.** Rationale belongs in a separate document, not in the rule text.

## Key Research Citations

- **Context rot** -- Output quality degrades well before context fills. 200K window shows degradation at 50K. Extra rule words actively degrade compliance. https://research.trychroma.com/context-rot
- **Prompt bloat** -- Quantified impact of unnecessary tokens on LLM output quality. https://mlops.community/the-impact-of-prompt-bloat-on-llm-output-quality/
- **Commander's Intent (US Army ADP 6-0)** -- Purpose, method, end state. Must be understood two echelons down. Shared vocabulary eliminates lengthy explanations. https://www.globalsecurity.org/military/library/report/call/call_98-24_ch1.htm
- **Less context = better performance (Greyling, 2026)** -- 144-microservice study. Claude Code: 73.7% accuracy with minimal prompts, 63.2% with detailed prompts. Over-specification constrains reasoning. https://cobusgreyling.medium.com/ai-agents-are-better-at-building-from-scratch-with-less-context-e656ee8bb524
- **Anthropic: specific vs general principles** -- Single general principle performed comparably to dozens of specific rules. https://www.anthropic.com/research/specific-versus-general-principles-for-constitutional-ai
- **Anthropic: effective context engineering** -- "Find the smallest set of high-signal tokens." https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- **Aviation checklist design (Degani & Wiener, NASA)** -- 5-8 items per checklist, 5-8 words per item (Miller's 7+-2). Checklists verify state, not teach procedure. Too long = skipped items. https://flightsafety.org/asw-article/making-a-list/

## Good vs Bad Examples

**BAD:** "The session that reads an act file MUST do exactly one of three things: (1) complete all work... (2) promote... (3) if THIS session can't act..."
**GOOD:** "Promote to backlog, create inbox items if cross-project, transition to reference with Tracked-by:."

**BAD:** "The first session to encounter an act file MUST: promote all actionable items to backlog entries..."
**GOOD:** Same one-liner above. The branching logic, numbered options, and "MUST" scaffolding around a single imperative are Pattern 9 (over-engineered rule text).

**Why the good versions work:** One flat imperative. No decision tree. The executor already knows what "promote to backlog" means -- the rule just needs to say when to do it, not re-teach the procedure.
