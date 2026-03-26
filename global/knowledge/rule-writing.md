# Rule Writing — Quality Checklist

**Load when:** Writing or proposing new rules for CLAUDE.md, project rules, or knowledge files.

## Principles

1. **Target the root cause, not the symptom.** If the failure was "didn't look up before asking," the rule is about the lookup step — not about "never ask."
2. **State the principle, not the checklist.** Don't enumerate sources/tools — state what behavior is expected. Explicit source lists become stale and miss the point.
3. **Minimal specificity.** If the rule works without naming a specific file/tool/path, leave those out. Overly specific rules break when the environment changes.
4. **No overkill.** PST archive search for a person lookup is disproportionate. Rules should match the scale of the problem.
5. **Get the target right.** Read the proposed rule back: does it actually prevent the failure that triggered it? If the failure was "asked user instead of looking up," a rule about "never asking" misses the point — the fix is "look up first."
6. **Generalizable over project-specific.** If the rule applies to all projects, put it in global CLAUDE.md. If project-specific, keep it in the project CLAUDE.md. Don't duplicate.
7. **One rule, one behavior.** Don't pack multiple behaviors into one rule. Each rule should prevent exactly one failure mode.

## Anti-Patterns

- **Symptom-targeting:** "Never do X" when the real issue was "do Y before X"
- **Source enumeration:** Listing every file to check instead of stating the principle
- **Overcorrection:** Banning an action entirely when the issue was just sequencing
- **Kitchen-sink rules:** Rules that try to cover every edge case instead of stating the principle clearly
- **"I'll remember" rules:** Rules that rely on behavioral commitment rather than structural change. If it can be automated (hook, script), automate it instead of writing a rule.

## Process

1. State the failure in one sentence
2. Identify root cause (not symptom)
3. Write the rule targeting root cause
4. Read it back: does it prevent the failure?
5. Check: is it the minimum necessary? Remove unnecessary specificity.
6. Check: does it accidentally prevent correct behavior? (e.g., "never ask user about people" prevents legitimate questions)
