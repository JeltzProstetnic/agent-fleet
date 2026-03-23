# Session Log

Full session history. Newest first. Never pruned.

<!-- Sessions are appended here by rotate-session.sh -->

### 2026-03-23T18:45Z — WSL
**Goal:** Work through open todos, inbox items, template propagation, VM test prep, anti-lockout hardening
**Completed:**
- OpenClaw vs agent-fleet positioning doc
- Installer dual-mode UX design doc
- 3 cfg inbox fixes (Gmail draft rule, communication-policy, EPUB/Kindle)
- WSL postmortem → CFG-252/253 promoted
- Cat 3 template propagation (session-protocol, settings.json hooks)
- Manifest stamped — 0 flagged
- Test VM (Ubuntu-24.04 WSL instance) created and provisioned
- agent-fleet cloned + setup.sh in VM — all working
- Hook dry-run: SETUP_PENDING correctly detected
- LOCKOUT FIX: set -e removed from afleet.sh, fallback launch, all guards
- 14-test integrity suite (test-afleet-integrity.sh)
- CFG-254: afleet family added to template-sync-manifest
- CFG-255-258 backlog items created (call-graph, wrapper, curl timeouts, python3 guard)
**Key Decisions:**
- OpenClaw = different category. Position against "dotfiles approach."
- Installer dual-mode: guided vs --auto. P2 priority.
- Test VM via WSL2 instance (not Multipass — Hyper-V needs reboot)
- CRITICAL: set -e in launcher is the root cause of ALL lockouts. Removed permanently.
- afleet.sh must NEVER use set -e. Integrity test enforces this.
- install-skill-collections.sh bug: writes to global enabledPlugins (hook auto-fixes)
**Pending at shutdown:** E2E onboarding test with API key (next session)
**Recovery/Next session:**
Test VM live: `wsl -d Ubuntu-24.04 -u aftest`. Cleanup: `wsl --unregister Ubuntu-24.04`.

### 2026-03-23T18:25Z — WSL
**Goal:** Work through open todos, inbox items, template propagation, VM deployment test prep
**Completed:**
- OpenClaw vs agent-fleet positioning doc (`docs/positioning-vs-openclaw.md`)
- Installer dual-mode UX design (`docs/design-installer-dual-mode.md`)
- 3 cfg inbox fixes (Gmail draft rule, communication-policy, EPUB/Kindle)
- WSL postmortem cleanup → CFG-252, CFG-253 promoted to backlog
- Cat 3 template propagation (session-protocol + settings.json hooks)
- Manifest stamped — template-push now 0 flagged
- Committed stale agent-fleet changes (hooks + infrastructure CLAUDE.md)
- Test VM created (Ubuntu-24.04 WSL instance, user aftest)
- Test VM provisioned (git, Node.js 22, npm, Claude Code 2.1.81)
- agent-fleet cloned + setup.sh run in test VM — all symlinks, hooks deployed
- Hook dry-run: SETUP_PENDING correctly detected, onboarding would trigger
**Key Decisions:**
- OpenClaw = different category (messaging assistant vs fleet ops). Position against "dotfiles approach" instead.
- Installer dual-mode: guided (TTY) vs automated (--auto/CI). Recommended P2.
- Test VM: WSL2 second instance (Ubuntu-24.04) instead of Multipass (Hyper-V not enabled, needs reboot)
- install-skill-collections.sh bug found: writes plugins to global enabledPlugins (hook auto-fixes, but install should use per-project)
**Pending at shutdown:** E2E test with API key (user chose option 1, deferred to next session)
**Recovery/Next session:**
Test VM is live at `wsl -d Ubuntu-24.04 -u aftest`. To run E2E test: set ANTHROPIC_API_KEY and run afleet. Cleanup: `wsl --unregister Ubuntu-24.04`.

### 2026-03-23T17:05Z — WSL
**Goal:** Work through open todos and inbox items — agent-fleet tasks + cross-project triage
**Completed:**
- OpenClaw vs agent-fleet positioning doc (`docs/positioning-vs-openclaw.md`)
- Installer dual-mode UX design (`docs/design-installer-dual-mode.md`)
- cfg-agent-fleet quick fixes (Gmail draft rule, communication-policy, EPUB/Kindle)
- WSL postmortem cleanup (promoted CFG-252, CFG-253 to backlog, marked reference)
- Template propagation (11 files synced, 4 Cat 3 flagged for manual review)
- Committed agent-fleet stale changes (hooks + infrastructure CLAUDE.md)
**Key Decisions:**
- OpenClaw is a different category (messaging assistant vs fleet ops) — no direct positioning needed, position against "dotfiles approach" instead
- Installer dual-mode: guided (TTY) vs automated (--auto/CI) — recommended P2 priority
- CFG-252 (postgres MCP exclusion) and CFG-253 (Steam Deck CC update) promoted from postmortem
**Pending at shutdown:** VM deployment test (needs user interaction with Multipass)
**Recovery/Next session:**
Session is straightforward triage+execution. Main agent-fleet inbox items done. Remaining: chaos audit (heavy, ext8tb needed), VM test (interactive).

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
