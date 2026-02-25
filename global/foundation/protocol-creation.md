# Protocol Creation — Complex Domains

**When a project involves intensive, repeated engagement with a complex knowledge domain (e.g., Twitter engagement strategy, academic publishing, client communication), mistakes WILL happen due to accumulated complexity. When they do:**

1. **Immediately write a protocol document** capturing the rule that prevents recurrence
2. **Place it in the appropriate location:**
   - **Global** (applies across projects): `~/claude-config/global/domains/<domain>/<protocol>.md`
   - **Project-specific**: `<project>/.claude/knowledge/<domain>-protocol.md`
3. **Reference it from the project's `CLAUDE.md`** with "load when" criteria
4. **Do NOT rely on memory files for operational rules** — memory is for orientation and pointers, protocols are for rules

## Triggers for Creating a New Protocol

- A mistake was made due to domain complexity (not a one-off typo, but a systemic issue)
- The same type of decision comes up repeatedly and needs consistent handling
- The domain has implicit rules that aren't obvious from code/files alone (social norms, workflow sequences, etiquette)
- Multiple sessions work in the same domain and need to stay consistent

## Protocol Structure (minimum)

- What the protocol covers and when to load it
- Hard rules (MUST / MUST NOT)
- The mistake that triggered the protocol (root cause, so future sessions understand WHY)
- Checklists or decision procedures where applicable

## Why This Exists

**This is self-healing documentation.** Every domain-complexity mistake becomes a protocol that prevents the next one. The cost of writing a protocol is one session. The cost of repeating the mistake is unbounded.

The pattern was established after repeated incidents where the same class of mistake recurred because no formal rule existed. Each incident cost recovery time. The protocols that emerged have prevented all recurrence.
