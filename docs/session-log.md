# Session Log

Full session history. Newest first. Never pruned.

<!-- Sessions are appended here by rotate-session.sh -->

### 2026-03-12T18:35Z — WSL
**Goal:** Work on open backlog tasks — do AFT-31, AFT-36; prep AFT-32, AFT-33, AFT-39/40/41
**Completed:**
- Inbox task: Add `.session-lock` to `.gitignore` (93cf243)
- AFT-31: Created template-sync-manifest.md with CRC32 hashes for 32 files (ed003d9)
- AFT-36: Fleshed out dms-guide.md from 32 to 170 lines (d884283)
- AFT-32 prep: Investigated filtered-push message leak — root cause at line 214-216, 4 fix options
- AFT-33 prep: Investigated --reconfigure-mcp — flag accepted by install.sh but never parsed by lib.sh
- AFT-39/40/41 prep: Investigated CI infrastructure — 32 test suites, custom framework, paths documented
**Key Decisions:**
- AFT-31: Manifest tracks same file set as cfg-agent-fleet version, with template hashes. 11 identical + 21 intentional-diff.
- AFT-32 prep: Recommend option A (pattern-based sed sanitization) reusing PERSONAL_DATA_PATTERNS from sync.sh.
- AFT-33 prep: Fix is add --reconfigure-mcp to parse_common_args() in lib.sh + check before early-return in configure_mcp_servers().
- AFT-39/40/41: Implementation order should be 41 (preflight) → 40 (integration) → 39 (CI workflow) per hardening plan Day 1→2→3.
**Pending at shutdown:** Nothing

### 2026-03-12T18:08Z — WSL
**Goal:** Work on open P2 backlog items (AFT-29, AFT-30)
**Completed:**
- AFT-30: macOS .zshrc support — detect_shell_rc()/detect_shell_rc_name() in lib.sh, updated install-base.sh, configure-claude.sh, install.sh. 8/8 tests.
- AFT-29: upgrade.sh with rollback — setup/scripts/upgrade.sh with pre-upgrade tags, --rollback, --list-tags, --dry-run, --skip-deploy. 9/9 tests.
- Backlog updated (both items moved to Done)
**Key Decisions:**
- detect_shell_rc() uses distro detection (macOS → .zshrc) plus $SHELL check (*/zsh → .zshrc, else .bashrc)
- upgrade.sh uses git tags (pre-upgrade-TIMESTAMP) for rollback — lightweight, no separate backup infra needed
- upgrade.sh exits early if already up-to-date (no tag created for no-op upgrades)
**Pending at shutdown:** Nothing
**Recovery/Next session:**
All work committed and pushed. No pending items.

### 2026-03-12T17:40Z — WSL
**Goal:** Resolve vault-ops deferral, mark inbox complete, backlog items AFT-34/35/37/38
**Completed:**
- Verified vault-ops.md + age-encryption.md paths already generic — no changes needed
- Marked all 8 agent-fleet propagation inbox items [x] complete
- Deleted docs/pending-template-propagation.md (fully resolved)
- AFT-34: Merged onboarding-guide.md into getting-started.md (troubleshooting added, duplicate deleted)
- AFT-35: Populated decisions.md (2 → 14 entries)
- AFT-37: Created CONTRIBUTING.md
- AFT-38: Generalized OpenClaw → "unattended AI agent" in security-one-pager
**Key Decisions:**
- vault-ops.md/age-encryption.md: No changes needed — template already uses placeholder paths
- AFT-34: Merged (not differentiated) — onboarding-guide added almost nothing beyond getting-started + README
- AFT-38: Replaced product name with generic category — template shouldn't reference specific competitors
**Pending at shutdown:** None
**Recovery/Next session:**
All work committed and pushed. No recovery needed.

### 2026-03-12T16:47Z — WSL
**Goal:** Complete remaining template propagation (8 items from docs/pending-template-propagation.md)
**Completed:**
- Item 1: learn-protocol.md 5-tier hierarchy (8896575)
- Item 2: CLAUDE.md drafts/ + steps 8+10 + inbox skip + model-agnostic (23aa11e, 80eb14d)
- Item 3: config-check.sh symlink validation, severity tags, ACT_PENDING, TMUX, .txt, git-behind (b191369)
- Item 4: project-setup.md drafts/ + 3 new CLAUDE.md rules (80eb14d)
- Item 5: sync.sh timestamp guard for project rules (5b99cf7)
- Item 6: ask-passphrase.sh (226ee37)
- Item 7: fleet-issue.sh (scrubbed), session-lock.sh, afleet.sh (226ee37)
- Item 8: clean-pending-files.sh — N/A
**Key Decisions:**
- fleet-capabilities.md 3-tier grouping: NOT propagated — template intentionally simplified, Life OS section is personal
- clean-pending-files.sh: NOT propagated — cfg has deprecated wrapper, agent-fleet has full implementation
**Pending at shutdown:** vault-ops.md/age-encryption.md path refs (minor, deferred)
**Recovery/Next session:**
All work committed. 7 commits on main. Push pending.

### 2026-03-12 16:35 — WSL
**Goal:** S1b continued — propagation checks, lrn fixes
**Completed:**
- Propagated vault-ops trigger + fleet-issue-protocol trigger to agent-fleet
- Propagated fleet-issue-protocol.md knowledge file (scrubbed)
- lrn: tightened propagation rule from session-end to immediate (both repos)
- Updated pending-template-propagation.md with item 8 (cfg 2026-03-12 outputs)
**Key Decisions:**
- Propagation check rule changed from "before session end" to "immediately after each edit" — template-only fixes are dead on arrival until cfg gets them too
**Pending at shutdown:** None — all handoff in pending file
**Recovery/Next session:**
All work committed and pushed. Handoff via docs/pending-template-propagation.md (8 items, sub-tasks tracked with checkboxes).

### 2026-03-12 16:20 — WSL
**Goal:** S1b — Review and commit S1a template sync (12 new files, 6 merged files) after personal data scrub
**Completed:**
- Reviewed all 18 files for personal data leaks — clean
- Fixed test-context-budget.sh skip guard for missing statusline.sh
- Committed and pushed: 777e606
- Marked S1a + context-budget inbox items [x]
**Key Decisions:**
- Added skip guard to context-budget tests rather than making them fail — statusline.sh is a deployed artifact not present in the template repo
- Remaining template propagation inbox items (learn-protocol, drafts/, collect guard, token optimization, rule audit, ask-passphrase) left open — only partially covered by S1a
**Pending at shutdown:** None
**Recovery/Next session:**
All work committed and pushed. No handoff needed.

### 2026-03-10T17:15Z — WSL
**Goal:** Propagate 3 template changes from cfg-agent-fleet to agent-fleet
**Completed:**
- Read cross-project inbox — identified 3 pending agent-fleet template propagation tasks
- Task 1: SteamOS pre-flight — added steamos_preflight() to afleet.sh with env var overrides
- Task 2: Statusline rename — statusline.sh→statusline-command.sh across sync.sh, configure-claude.sh, settings.json, tests
- Task 2b: Added 2 new CLAUDE.md rules (tmux/nohup, check deployed config)
- Task 3: GPI — created gpi.sh CLI (159 lines), updated statusline with GPI renderer + context budget sidecar, 24 tests
- All tests pass: statusline 27/27, afleet 21/21, sync 24/24, GPI 24/24
- Marked 3 inbox items [x] in cfg-agent-fleet cross-project inbox
**Key Decisions:**
- Kept template persona names as Assistant/Supporter (generic), not Bartl/Elsa (personal)
- Excluded cost display from template statusline (personal deployment feature)
- GPI log parsing kept as-is (rsync-specific patterns) — useful generic pattern
**Pending at shutdown:** None
**Recovery/Next session:**
All work committed. No pending actions.

### 2026-03-09 23:15 — WSL
**Goal:** README/docs update, full audit, deployment mechanism planning
**Completed:**
- Inbox processed — session-protocol.md Rule 10 rewrite applied
- Stale pending file cleaned (pending-multi-session-plan.md deleted)
- README audit (3 agents: README, docs, deployment mechanisms)
- README fixes: test count 365, step count fixed, context budget corrected, sync table expanded (9 commands), dir structure updated, Context7 added to MCP table
- getting-started.md: vault path + project path fixed
- onboarding-guide.md: test count updated (365/22), mclaude→claude, Context7 added
- agent-teams-vs-team-mode.md: all cc-mirror/mclaude/Session 60 refs removed
- hardening-plan.md: status updated (365 tests exist), personal machine refs cleaned
- session-log.md: reset to clean template (dev history removed)
- CHANGELOG.md created (v0.2 initial + unreleased v0.3)
- Backlog re-established with AFT-29 through AFT-41 (deployment, docs, CI/CD)
- Plan audit: deployment gaps → backlog items, existing infrastructure verified
- Tests pass (22 suites, all green)
**Key Decisions:**
- Session-log.md cleaned: dev history from S1-S6 sync not useful for template users
- CHANGELOG.md created: needed for users tracking versions between upgrades
- Deployment/update mechanism issues → backlog (AFT-29 to AFT-41): upgrade rollback, macOS zsh, manifest, filtered-push messages, docs consolidation, CI/CD
- hardening-plan.md kept but updated status — still useful as roadmap for remaining CI/CD work
**Pending at shutdown:** Commit and push
**Recovery/Next session:**
All changes are unstaged. Commit and push to complete session.
