# Session Log

Full session history. Newest first. Never pruned.

<!-- Sessions are appended here by rotate-session.sh -->

### 2026-03-20T20:20Z — WSL
**Goal:** Inbox triage + propagation catch-up
**Completed:**
- Hook propagation: 6 hooks total (3 updated, 3 new — all sanitized)
- /init nuke defense: marker in CLAUDE.md + warning in getting-started.md
- CI test suite: 3 fixes, 43/43 suites pass (sanitize_text, test-check-helpers, statusline path)
- CLAUDE.md Cat 3 propagation: 9 rule changes applied, 10 placeholder domain files
- Memory rule revised: NEVER→NOT, ALWAYS→usually (both repos synced)
- All 3 major inbox items resolved
**Key Decisions:**
- Memory policy: softened from absolute prohibition to "usually wrong" — auto-memory supplementary for things fleet doesn't cover
- sub command: prohibit commits (cfg version) over allow-with-trailer
- Quick commands: "anywhere in message" scope, not "alone"
- Persona hook: trust SessionStart hook injection, save 2 tool calls at startup
**Pending at shutdown:** OpenClaw positioning doc, installer dual-mode UX, VM deployment test
**Recovery/Next session:**
All work committed and pushed. No open branches or unstaged changes.

### 2026-03-20T19:35Z — WSL
**Goal:** Inbox triage + propagation catch-up (day mode until 20:00)
**Completed:**
- Hook propagation: 3 existing hooks committed (afk-deactivate, config-auto-sync, rtk-rewrite)
- 3 new hooks added (cfg-boundary-guard, critical-edit-notify, 17-fleet-updates) — sanitized
- /init nuke defense: marker in CLAUDE.md + warning in getting-started.md
- cfg stale session lock cleaned
- template-push Cat 1+2 synced
- Inbox updated (1 resolved, 1 partially updated)
- Disabled checks (14, 15, 15b) verified — cfg-specific state, not template drift
- CLAUDE.md Cat 3 drift: 9 rule changes applied, Memory Architecture conflict resolved (cfg NEVER wins)
- CI test failures: 3 fixes, 43/43 suites pass
- 10 placeholder domain files for new triggers
- All 3 inbox items resolved (propagation, /init defense, CI)
**Key Decisions:**
- Memory policy: cfg's "NEVER the answer" rule wins over agent-fleet's nuanced Memory Architecture section
- sub command: prohibit commits (cfg) over allow-with-trailer (agent-fleet)
- Quick commands: "anywhere in message" scope (cfg) over "alone" (agent-fleet)
- Persona hook injection: trust SessionStart hook, save 2 tool calls at startup
**Pending at shutdown:** OpenClaw positioning doc, installer dual-mode UX, VM deployment test

### 2026-03-20T19:19Z — WSL
**Goal:** Inbox triage + propagation catch-up (day mode until 20:00)
**Completed:**
- Git sync check — up to date
- SystemMessage items surfaced
- Hook propagation: 3 hooks committed (afk-deactivate, config-auto-sync, rtk-rewrite)
- /init nuke defense: marker added to CLAUDE.md + warning in getting-started.md
- cfg-agent-fleet stale session lock cleaned
- template-push ran (Cat 1+2 synced, no content changes)
- Inbox items updated (2 resolved, 1 partially updated)
**Key Decisions:**
- (no decisions recorded)
**Pending at shutdown:** Background agents, remaining propagation, OpenClaw doc, installer design
