# Session Log

Full session history. Newest first. Never pruned.

<!-- Sessions are appended here by rotate-session.sh -->

### 2026-03-13T18:42Z — DESKTOP-32ILURB
**Goal:** Execute all 8 open items — 5 backlog (AFT-32/33/39/40/41) + 3 inbox propagation tasks.
**Completed:**
- AFT-32: filtered-push commit message sanitization — sanitize_text() + 14 tests
- AFT-33: --reconfigure-mcp flag fix — lib.sh + configure-claude.sh + 7 tests
- AFT-39: GitHub Actions CI — workflow + 4 Dockerfiles + smoke-test.sh
- AFT-40: Integration test script — 10 tests
- AFT-41: Preflight check script — setup/preflight.sh + install.sh hook + 9 tests
- Inbox: CFG-101 follower-mode propagation — follower-mode.md + CLAUDE.md trigger
- Inbox: vault-ops rules 1-6 + communication-policy persona email rules + mcp-catalog
- Inbox: CFG-101 session locking — afleet.sh, statusline, auto-sync, afd-lib.sh, 22 tests
- Shutdown checklist executed
**Key Decisions:**
- Used 4 parallel worktree subagents (non-overlapping files), merged all cleanly
- 51 new tests total, all passing. 33/37 suites pass (4 pre-existing failures)
- Backlog now empty. 3 inbox items marked done.

### 2026-03-13T18:50Z — WSL
**Goal:** Deployment disaster post-mortem — audit all fixes, plan E2E testing, resolve config divergence
**Completed:**
- Fetched GitHub issues (only #1 — sync.sh false positive)
- Audited session logs — 12 fixes across 3 sessions mapped
- Deep code audit — all 12 fixes verified OK, 2 critical issues found
- Fixed GitHub #1 (sync.sh inbox counter) — committed 340ac3a, issue closed
- Downloaded Ubuntu 24.04 rootfs for E2E testing (C:\WSL\, 341MB)
- Designed E2E test plan (28 test cases, TAP, WSL disposable instances)
- Merged config-check.sh bidirectional divergence — committed b47f7a4
- Sanitization audit — CLEAN, 0 leaks
- Updated cfg inbox (3 new items, 2 completed, 2 partial updates)
**Key Decisions:**
- config-check.sh merge strategy: start from template, add cfg checks, use letter suffixes for numbering conflicts (12a/12b, 13/13b)
- E2E testing: WSL2 `wsl --import` for disposable instances (not Docker, not LXC)
- Session lock false trigger: routed to cfg for investigation (shared hook paths)
- IvoclarR-D-AIOrg in install.sh: advisory only, user decision pending
**Pending at shutdown:** Push 2 commits, E2E harness implementation, CFG-101 remaining files
**Recovery/Next session:**
If session dies: 2 unpushed commits on main. Push with `git -C ~/agent-fleet push origin main`. Handoff file at docs/pending-deployment-audit.md.

### 2026-03-13T17:38Z — WSL
**Goal:** Fix mangled console output caused by startup spinner in afleet.sh
**Completed:**
- Identified root cause: Braille spinner background process writing \r escape codes fights with CC's TUI/statusline
- Replaced spinner with static "Starting session..." message in agent-fleet/setup/scripts/afleet.sh
- Propagated same fix to cfg-agent-fleet/setup/scripts/afleet.sh (the deployed symlink target)
- Verified afleet is symlinked to cfg version — fix is live immediately
**Key Decisions:**
- Replaced animated spinner with static text rather than trying to time-coordinate spinner shutdown with TUI startup. The "Syncing repos" spinner (pre-TUI) was left intact since it runs and stops before CC launches.
**Pending at shutdown:** None
**Recovery/Next session:**
Fix is complete. No follow-up needed.

### 2026-03-13T17:30Z — WSL
**Goal:** Fix deployment issues (AFT-42..46 fresh install UX bugs)
**Completed:**
- AFT-42: Removed CC_MIRROR_SPLASH from template settings.json (no banner overlap)
- AFT-43: Added spinnerTipsEnabled:false to template settings.json
- AFT-44: Verified statusLine block already in template, added TWEAKCC_CONFIG_DIR
- AFT-45: Already fixed (commit be990d1)
- AFT-46: Added Check 2d to config-check.sh for .setup-pending detection (2 tests)
- Fixed deployed config: PROMPT_SUGGESTION set to "0" on this machine
- Backlog updated, pending file deleted
**Key Decisions:**
- Removed splash banner entirely from template (CC_MIRROR_SPLASH=0 by default) rather than finding a hideStartupBanner option — simpler, no overlap risk
- Check 2d added to template config-check.sh only (not cfg version) since .setup-pending only exists on fresh installs
**Pending at shutdown:** None
**Recovery/Next session:**
All changes committed. Two commits: 3e0b06c (code fixes) and a405517 (pending file cleanup).

### 2026-03-13T16:50Z — WSL
**Goal:** Fix fresh-install deployment bugs discovered during remote WSL deployment test
**Completed:**
- Fix nvm/.npmrc conflict in install-base.sh (detect nvm, skip prefix, clean stale)
- Ensure ~/.local/bin in PATH via .bashrc
- Add yellow spinner to afleet pre-pull phase + refactor into start_spinner/stop_spinner
- Fix empty picker on fresh install (skip when no dashboard-cache)
- Fix project detection (CLAUDE.md alone sufficient, no .claude/ dir required)
- Critical: install.sh now runs sync.sh setup (Phase 3 — was missing entirely)
- Guard all registry.md callers in afleet (missing file on fresh install)
- git-sync-check: handle missing remote gracefully on fresh install
- Verify: split hard errors vs soft warnings (CLAUDE.local.md = soft warning)
- 7 install-base nvm tests, afleet test updated for marker-file approach
- Backlog items AFT-42..46 for remaining cosmetic/UX issues
**Key Decisions:**
- install.sh now has 3 phases: base system → CC config → global config deploy (sync.sh setup)
- Verification split: V1-V7,V10-V11 = hard errors, V8-V9 = soft warnings (first-run expected)
- registry.md absence normal on fresh install — all callers guard for it
- Picker only shows when both registry.md AND dashboard-cache.md exist
**Pending at shutdown:** Propagate sync.sh and git-sync-check.sh fixes to cfg-agent-fleet
**Recovery/Next session:**
If continuing deployment fixes: AFT-42..46 in backlog.md cover remaining UX issues (logo, tips, CRI, onboarding).
Propagation to cfg-agent-fleet still needed for sync.sh and git-sync-check.sh changes.

### 2026-03-13T14:10Z — WSL
**Goal:** Update README.md with all recent changes, push to GitHub, enable template repo
**Completed:**
- Updated README.md comprehensively (afleet launcher, 570/33 tests, GPI, session hooks, key scripts table, directory tree, upgrade details)
- Committed and pushed 6 commits to origin/main
- User enabled "Template repository" setting on GitHub
**Key Decisions:**
- afleet replaces `claude` as the documented launch command in README
- Removed Memory MCP server from MCP table (no longer configured)
**Recovery/Next session:**
All work committed and pushed. No pending items.

### 2026-03-13T08:30Z — WSL
**Goal:** Friday morning triage — inbox tasks, propagation work
**Completed:**
- Propagate CLAUDE.md rule quality fixes (shutdown guard, token cost, feature self-integrity removed, cls/end messages, lrnd removed)
- Propagate cfg hardening scripts (config-check.sh Checks 28+29, lib.sh ensure_tool_paths, configure-claude.sh --path-prefix, test-nvm-path.sh)
- Propagate lrn protocol rewrite (4-branch root cause analysis) + documentation coherence rule
**Key Decisions:**
- Feature self-integrity rule removed from template (design requirement, not behavioral rule)
- lrnd quick command removed from template (matching cfg)
- Bidirectional script diffs preserved — agent-fleet keeps its unique features (git identity, shell RC detection, statusline deployment)
**Pending at shutdown:** Commit and push
**Recovery/Next session:**
All edits applied. Tests pass (12/12 NVM, 72/77 config-check — 2 pre-existing failures). Need commit + push.

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
