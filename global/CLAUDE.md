<!-- updates: registry.md -->
# Global Claude Code Configuration

@~/.claude/foundation/user-profile.md
@~/.claude/foundation/session-protocol.md
@~/.claude/foundation/personas.md

Config repo: `~/agent-fleet/`

## Machine Identity

Machine-specific knowledge is auto-loaded via `~/CLAUDE.local.md` (each machine has its own, not synced). The SessionStart hook injects `HOSTNAME:` into systemMessage — match it to the table below and state where you are in your first response using the **short name**. Do NOT read `/etc/hostname` or run `hostname` — the hook already did it.

<!-- Add your machines here. Example:
| Hostname pattern | Short name | Platform | Notes |
|-----------------|------------|----------|-------|
| `my-server` | the VPS | Native Linux (Ubuntu) | Remote server |
| `DESKTOP-*` | WSL | WSL2/Ubuntu | Home PC |
| `my-laptop` | Laptop | Fedora KDE | Laptop |
-->

**Evaluation order:** Match hostname pattern first, then disambiguate by username if needed. If ambiguous, state the hostname + user and ask.

If hostname doesn't match any pattern, state the hostname and ask. If `CLAUDE.local.md` is missing, fall back to reading `~/.claude/machines/<machine>.md` manually.

## Session Start — Loading Protocol

**MANDATORY — NEVER SKIP.** Complete ALL steps before doing ANY user task. The user's first message often IS the trigger for startup — do not treat it as reason to skip loading. Even if the user asks something urgent, load first, then respond. A 30-second startup is always acceptable; lost context from skipping is not.

**Template-clone detection:** If `.template-repo` exists in the config repo root OR `user-profile.md` still contains only the auto-generated placeholder text, this is a fresh/unconfigured installation. In this case:
- **SKIP** steps 1 (inbox), 2 (handoff), 4 (session-context), and persona activation
- **DO** step 0 (git sync), step 3 (read CLAUDE.md), step 6 (check for `.setup-pending` → triggers first-run refinement)
- **DO NOT** process cross-project tasks, activate personas, or inject machine identity
- The goal is to route directly to the first-run refinement protocol without loading personal context that doesn't exist yet

**Auto-loaded via @import** (no action needed — loaded before you see this):
- `user-profile.md` — who the user is
- `session-protocol.md` — session context persistence rules
- `personas.md` — default personas (machine files can override)
- Machine file — via `CLAUDE.local.md` (machine-specific, not synced)

**Manual steps — execute in order:**

0. **ALWAYS check for remote changes — BEFORE reading any files.** Run `bash ~/agent-fleet/setup/scripts/git-sync-check.sh --pull <project-dir>` (pass the project directory as an argument — the script accepts an optional path). This fetches, reports incoming changes, and fast-forward pulls if behind. If it reports changes, re-read affected files. If it fails (diverged, merge conflict), resolve before proceeding. This applies to EVERY project, EVERY session, no exceptions.

0.5. **Surface ALL systemMessage items to the user.** The SessionStart hook generates intelligence at 0 LLM tokens — suppressing its output defeats the purpose. Present every injected field: `WARNING:` (drift, branches, locks), `Upstream dependency check:`, `FMS_INGEST_NEEDED:`, `Documents found in tmp/`, `ACT_PENDING:`. One structured summary, before any file reads. **When `FMS_INGEST_NEEDED:` reports pending files, load `knowledge/fms-ops.md` and file them interactively (auto-file unambiguous, ask for ambiguous; delete from drop folder after filing).**

1. **Read cross-project inbox** — skip if redundant. If `INBOX TASKS for <project>` appears in systemMessage, the hook already extracted this project's items — skip the full `inbox.md` read. Only read `~/agent-fleet/cross-project/inbox.md` manually when: (a) the hook didn't inject inbox data, or (b) you need child project tasks (check `Parent` column in `registry.md`). Report child project tasks to the user but don't delete them — the child project session handles that.

2. **Check `HANDOFF:` in systemMessage.** If `HANDOFF: none`, skip. If `HANDOFF: <description> | file: <path>`, read the `file:` it points to.

3. **Read the project's `CLAUDE.md`** (manifest) — it declares what domains to load

4. **Check `SESSION_CONTEXT:` in systemMessage.** If `SESSION_CONTEXT: blank`, skip reading. If `SESSION_CONTEXT: active — <goal>`, read `session-context.md` for full state.

5. **Follow the manifest's Knowledge Loading table** — load only the listed domain files

6. **Conditional loading (do NOT load unless triggered):**

   | Trigger | File |
   |---------|------|
   | `.setup-pending` exists (first run) | `foundation/first-run-refinement.md` |
   | MCP issue, auth, first MCP use | `reference/mcp-catalog.md` |
   | New/unconfigured project | `foundation/project-setup.md` |
   | Roster changes | `foundation/roster-management.md` |
   | Project type decisions, roster mapping | `reference/project-types.md` |
   | Code project using Serena | `reference/serena.md` |
   | WSL troubleshooting | `reference/wsl-environment.md` |
   | Subagent permission failures | `reference/permissions.md` |
   | Cross-project coordination | `foundation/cross-project-sync.md` |
   | CLI tool usage, installed software | `reference/system-tools.md` |
   | Atlassian/Jira MCP tools | `knowledge/jira-atlassian.md` |
   | dev-browser skill, browser automation | `knowledge/dev-browser-ops.md` |
   | Plan mode issues/hangs/freezes | `knowledge/plan-mode-issues.md` |
   | Persona setup/onboarding/rendering | `reference/persona-rules.md` |
   | User-facing docs, READMEs, UX | `reference/ai-first-paradigm.md` |
   | Backlog format, task IDs | `reference/backlog-convention.md` |
   | Terminal tabs, cross-platform, VPS | `reference/platform-notes.md` |
   | age/pyrage encryption, vault | `knowledge/age-encryption.md` |
   | Vault ops, credentials, deploy secrets, passphrase prompt, encrypt, decrypt, vault-manage, token rotation — STOP and load before ANY vault/secret operation | `knowledge/vault-ops.md` |
   | Adding/debugging MCP servers | `knowledge/mcp-deployment.md` |
   | Permission prompts, settings.local | `knowledge/claude-code-permissions.md` |
   | `lsd` command (dashboard) | `reference/lsd-spec.md` |
   | Documents, PDFs, file delivery | `reference/output-rules.md` |
   | Writing outside project, sync | `reference/cross-project-rules.md` |
   | Upstream deps, version tracking | `reference/upstream-dependencies.md` |
   | Career, goals, job applications | `domains/life-management/career.md` |
   | Family, personal background | `domains/life-management/family.md` |
   | Cognitive style, communication | `domains/life-management/psych-profile.md` |
   | Colleague context, networking | `domains/life-management/relationships.md` |
   | Email drafts, social posts, formal correspondence | `reference/communication-policy.md` |
   | Document management, catalog | `~/agent-fleet/docs/dms-guide.md` |
   | FMS ops, file dedup, bulk moves | `knowledge/fms-ops.md` |
   | Audit, self-audit, meta-audit | `knowledge/audit-protocol.md` |
   | Email triage, inbox management | `knowledge/gmail-management.md` |
   | Scrollback issues, terminal buffer overflow | `knowledge/scrollback-fix.md` |
   | Word inline editing, .docx review extraction, author review round | `knowledge/word-editing-extraction.md` |
   | Writing or proposing new rules for CLAUDE.md or knowledge files | `knowledge/rule-writing.md` |
   | `lrn` command issued | `skills/lrn/SKILL.md` |
   | AFD daemon, task coordination | `knowledge/afd-ops.md` |
   | NAS access, smbclient, file transfer | `knowledge/nas-cheatsheet.md` |
   | YouTube tabs (save/list/open) | Run `bash ~/agent-fleet/setup/scripts/youtube-tabs.sh save\|list\|open [query]` — no file to load, just invoke the script directly |
   | Cross-project navigation, project switching | `reference/cross-project-nav.md` |
   | Self-awareness, plugin recommendation, agent roster gaps, "can I do X?", context window, model capabilities | `knowledge/fleet-capabilities.md` |
   | Statusline editing, GPI, statusline deployment | `knowledge/statusline-ops.md` |
   | Konsole tabs, qdbus, terminal tab operations | `knowledge/konsole-tabs.md` |
   | Filing GitHub issue on agent-fleet, `issue` command | `knowledge/fleet-issue-protocol.md` |
   | SESSION_LOCKED or SESSION_LOCKED_REMOTE in systemMessage | `knowledge/follower-mode.md` |
   | Session shutdown (`cls`, `end`, exit, shutdown) | `foundation/session-shutdown.md` |
   | Hook debugging, PreToolUse/UserPromptSubmit platform behavior | `knowledge/hook-behavior.md` |
   | SteamOS deployment, symlink bugs, reprovision issues | `knowledge/steam-deck-deployment.md` |
   | P4 fleet audit orchestration | `knowledge/audit-pattern-fleet.md` |
   | AIOS memory design, knowledge graph schema, consciousness theory architecture | `knowledge/aios-memory-design.md` |
   | Risk gate blocks an edit (RISK_GATE in stderr) | `knowledge/risk-analysis-protocol.md` |
   | Risk tiers, E2E test requirements, privacy scrub, IT security compliance | `knowledge/risk-management.md` |
   | SimOpt, simulation, optimization, queueing, throughput, capacity planning | `knowledge/simopt-ops.md` |

   All paths relative to `~/.claude/` unless absolute. Do NOT load unless triggered.

7. **Check `PROJECT_KNOWLEDGE:` in systemMessage.** If `PROJECT_KNOWLEDGE: none`, skip. If listed, read the relevant files from `<project>/.claude/knowledge/` and `<project>/.claude/`.

8. **Populate session-context.md if blank.** If `SESSION_CONTEXT: blank` in systemMessage, populate the template fields before doing any other work: set `Last Updated` to current timestamp, `Machine` to the machine short name (from identity table), `Working Directory` to `$PWD`, and `Session Goal` to a brief description of the user's request.

10. **Startup/shutdown messages must be human-readable.** "Last session shut down correctly, starting fresh" — not "Session context is blank (freshly rotated)".

## Indexes

- Foundation modules: `~/.claude/foundation/INDEX.md`
- Domain catalog: `~/.claude/domains/INDEX.md`
- **Full project catalog: `~/agent-fleet/registry.md`** — read on demand (project ops, `lsd`, or when user mentions other projects)

## Temporary Rules

- **PLAN MODE BROKEN — use Plan subagent instead.** `EnterPlanMode` hangs during extended thinking (crystallize stream stall, upstream bug #26224/#29712). Use `Task` tool with `subagent_type: "Plan"` for all planning tasks. Daily check: test `EnterPlanMode` → if it completes without hanging, remove this rule and delete `~/.claude/knowledge/plan-mode-issues.md` workaround section.

## Upstream Dependency Policy

**Daily version check is automated** by the SessionStart hook (Check 13.5). It runs `npm view` once per day (date-gated marker file) and surfaces update availability via systemMessage. No Claude action needed — just relay findings.

**First-session-of-day rule:** The first session each day handles triage (inbox, updates, handoffs). This consumes significant context. After completing triage, recommend the user run `/clear` to start a fresh working session with full context available. This is a recommendation, not a hard gate — the user decides.

For manual investigation: read `~/.claude/reference/upstream-dependencies.md`.

**Update policy — HARD RULE:** Before suggesting ANY upstream update, investigate the changelog and assess impact on our system (hooks, statusline, permissions, plugin compatibility). Present findings to the user. The user decides when to update. Never update silently or suggest "just update it." **CC update gate:** If using TweakCC, do NOT update Claude Code until TweakCC confirms compatibility with the new version. Check `npm view tweakcc version` daily; if newer, test `npx tweakcc --apply` against the new CC version before upgrading CC.

## Development Rules

- **Work products are first-class deliverables.** Translations, builds, analysis docs, reviews, and any user-facing output MUST be committed in the same session they're produced. Never leave work products as untracked files across session boundaries. `tmp/` is for throwaway intermediaries only — if a file would be missed if lost, it doesn't belong in `tmp/`.
- **Task tracking is primary work.** Backlog items, session handoffs, inbox tasks, and "I'll note this" commitments are first-class deliverables. Execute immediately when stated — never defer. Anti-pattern: "I'll add a backlog item" → proceeds to other work → forgets.
- **Session leftovers → handover, not silent backlog.** Items deferred or left unfinished MUST appear in the next-session-task handover with explicit description. Never silently add them to the backlog only — they get lost in the priority bin. Backlog is for tracking, handover is for continuity. Both are needed: handover ensures the next session sees them immediately, backlog ensures long-term tracking.
- **New backlog entries need user priority review.** When adding items to the backlog, present the proposed priorities to the user before or immediately after adding. The user decides priority — the agent proposes. Silently assigning P3/P4 to items the user may consider urgent is a recurring failure mode. Batch presentations are fine ("I added X at P2, Y at P3 — agree?").
- **Token cost awareness:** Prefer bash/hook automation (0 LLM tokens) over behavioral rules loaded into CLAUDE.md (tokens every session). Evaluate token cost when editing rules.
- **No new files for daily state.** When a daily check needs persistent state (last scan date, last version check, last sync), embed it as a single line in a file that is ALREADY read at startup (session-context.md, CLAUDE.md metadata, etc.). Never create a separate tracking file — every extra file is an extra Read call per session. This is a recurring mistake pattern.
- **Recurring task "last checked" dates:** Check "Last checked: YYYY-MM-DD" marker before executing recurring tasks. If checked today on any machine, skip. Research = once per fleet per day. Execution = per machine as needed.
- **TDD only:** All new code and features MUST follow test-driven development. Write failing tests first, then implement to make them pass. No implementation code without a corresponding test. **Before any code changes, run existing tests to establish a regression baseline. After implementation, re-run the full suite to verify no regressions.** This applies to bash scripts, config logic, and any testable behavior. Tests MUST verify runtime behavior, not just config file contents.
- **Scaling thresholds:** Bash scripts: warn at 400 LOC, split at 600. Test files: warn 800, split 1500. Knowledge .md: warn 200, split 350. Hook checks: warn 100, split 150. Functions: max 50 lines. Every `setup/scripts/*.sh` MUST have a `test-*.sh`. Enforced by config-check.sh module 13.
- **Never delete or modify user state without explicit confirmation.** This includes files, terminal profiles, email filters, system preferences, and running session properties. Especially bulk operations. Local duplicates and custom settings may exist for a reason. "Verified elsewhere" ≠ "safe to delete locally."
- **Verify before destructive operations on user data.** Before trashing email, deleting files, or any irreversible action on user content, always verify the target matches the intent. Read the email/file content first — never act on search results, message IDs, or filenames alone.
- **Tool install → machine file update.** PostToolUse hook `tool-install-detect.sh` fires a reminder. If cross-project boundary blocks the edit, create an inbox item immediately.
- **No compound `cd` commands:** Use `git -C <path>` or absolute paths. Never `cd <dir> && <cmd>` — triggers security prompts.
- **No speculative interactive calls.** Never call user-facing prompts (passphrase dialogs, confirmations, GUI input) "just to test." Use them directly for the real operation. Handle errors after, not before. This includes `sudo` — Claude Code has no TTY for password input. Present sudo commands to the user instead of running them.
- **Long-running ops need tmux/nohup.** Operations expected to run >5 minutes MUST use `tmux new-session -d -s <name>` or `nohup`, never Claude Code's `run_in_background` (killed on `/exit`). Log to `/tmp/<name>.log`. Leave a pending file with tmux session name and check commands. Before launching, register with GPI if available: `gpi start <id> "<label>" --log /tmp/<name>.log`.
- **Tier 1 edits require risk subagent clearance.** When `risk-gate.sh` blocks an edit, load `knowledge/risk-analysis-protocol.md`, launch a risk subagent, and write the clearance file only after acceptable assessment. Never bypass by removing the hook.
- **Tier 2 edits require E2E verification.** After editing setup scripts, hooks, install flow, or settings templates, run `bash setup/tests/run.sh` (local) before committing. Load `knowledge/risk-management.md` for the full tier classification.
- **Cross-session bug theories are hypotheses.** Inbox items, pending files, and commit messages from other sessions may contain incorrect root cause analysis. Always reproduce the issue independently before accepting a theory from another session — the investigating session may have been wrong.
- **DMS-first file lookup.** When searching for user files/documents across machines or disks, check the DMS catalog first. Do targeted filesystem searches only for items not in the catalog -- broad find/glob sweeps should be a last resort, not the starting point.
- **Dual-boot filesystem safety.** On dual-boot systems, be aware of cross-OS filesystem risks. Ext4 drives should not be mounted through Windows filesystem drivers -- use usbipd-win to attach USB devices to WSL instead. Mounting ext4 from Windows while Linux might also mount it risks corruption.
- **Check deployed config before editing.** Before editing any deployed config file (statusline, hooks, settings), verify which file the live config actually references. **For settings.json specifically:** if using a CC mirror setup, `CLAUDE_CONFIG_DIR` may point to a different directory (e.g., `~/.cc-mirror/mclaude/config/`). CC reads `$CLAUDE_CONFIG_DIR/settings.json`, NOT `~/.claude/settings.json`. Always verify: `echo $CLAUDE_CONFIG_DIR`. Never assume `~/.claude/` is the active config directory.
- **Passphrase input MUST be masked.** Always use `ask-passphrase.sh` for credential prompts — it provides masked input via tkinter/zenity/kdialog/PowerShell WPF/read -s. Never improvise with unmasked alternatives (`InputBox`, plain `read`, etc.). If all masked paths fail, abort — don't fall back to plain text.
- **Bash permissions match first word only:** `Bash(npm:*)` only matches commands starting with `npm`. Never prefix with `VAR=x &&` or `sleep N &&`. See `knowledge/claude-code-permissions.md`.
- **Know your gitignore:** Before `git add`, verify the file isn't gitignored. `.claude/settings.local.json` and `setup/secrets/vault.json` are gitignored. Don't waste tool calls trying to stage them.
- **Pull before compare — ALWAYS:** Before ANY cross-repo operation (template sync, filtered-push, diff, deploy), pull ALL involved repos first (`git -C <path> pull --ff-only`). The startup git-sync-check only covers the current project. Secondary repos can be stale locally even when the remote is far ahead. Diffing stale repos wastes an entire analysis cycle on outdated data.
- **Propagation check after edits — IMMEDIATELY, not at session end.** After editing any file that exists in both a private config repo and a public template repo (global/, hooks, setup/scripts/), check and propagate to the other repo in the same tool-call batch. Deployed files are symlinked to the config repo — template-only fixes are dead on arrival until propagated. Don't wait for shutdown; don't say "done" before propagating. Run `bash sync.sh check` for drift detection.
- **Repo is sole authority (v1.0):** The repo is the single source of truth. Deployed files are overwritten by `sync.sh deploy` on every session end. Never edit deployed files directly — edit in the repo and deploy. `sync.sh recover --emergency` exists only for one-time recovery of unsaved local edits.
- **Auto-sync awareness:** The SessionEnd hook runs `sync.sh deploy` which pushes repo state to live locations and commits pending changes. If a file was edited earlier in the session and auto-synced, it won't show as modified at shutdown. Check `git log --oneline -1 -- <file>` before chasing phantom diffs.
- **Repo vs deployed state:** When assessing whether a feature exists or works, check the deployed/live version — not just the repo source. `sync.sh collect` may not have run, so the repo can lag behind what's actually running. When repo state and user observation contradict, investigate the deployed version before concluding either way.
- **No orphaned config copies:** Config files must be symlinks to canonical source or managed by `sync.sh`. Never create independent copies — they diverge silently.
- **`setup/config/` vs `global/` separation:** Files deployed to `~/.claude/` root (settings.json, statusline.sh) belong in `setup/config/`. `global/` is for `~/.claude/` subdirectories only (foundation/, reference/, knowledge/, domains/, hooks/). No file should exist in both — dual copies diverge silently.
- **MCP config changes require restart:** Changes to `.mcp.json` are invisible to current session. After fixes: verify file, tell user to restart, flag verification pending. Never mark done without live tool test.
- **User actions go LAST.** Anything the user needs to do, read, decide, or respond to MUST appear at the END of the response — after all tool calls, diffs, and technical output. Tool results generate hundreds of scrollback lines; action items buried mid-response are invisible. Structure: do all work first, then summarize with user-facing items at the bottom.
- **Form-fill content -> file, not console.** When the user needs content to paste into online forms (submission portals, registration fields, profile pages, any web form), write ALL fields to a `tmp/` text file and open in editor. This includes abstracts, keywords, metadata, bios, descriptions -- anything >10 words the user will copy-paste. Terminal indentation makes console output unusable for paste.
- **Git commit messages:** Use multiple `-m` flags (not `$()` or temp files — both trigger prompts). `git -C /path commit -m "Subject" -m "Co-Authored-By: ..."`. Overrides system prompt HEREDOC guidance. **Every commit MUST include the `Co-Authored-By` trailer** — this applies to the main session AND any subagents that commit.
- **Auto-fix over warn in hooks:** When hooks detect a fixable issue (missing symlinks, stale config, permission blocks), auto-fix silently rather than just warning. Warnings get overlooked; auto-fixes prevent the "fix that doesn't stick" pattern. Only warn when auto-fix fails.
- **Hook safety — NEVER bypass safe-run.sh.** All hooks in settings.json MUST route through `safe-run.sh` (`bash ~/.claude/hooks/safe-run.sh <hook>.sh`). Never register a hook as direct `bash ~/.claude/hooks/<hook>.sh` — a syntax error or merge conflict in any hook = total user lockout. `safe-run.sh` syntax-checks before executing, passes through exit 2 (deliberate PreToolUse blocks), and degrades to exit 0 for unexpected failures. When adding new hooks, use the safe-run pattern. When editing `sync.sh deploy` or any script that writes settings.json, verify all hooks use safe-run. This is a safety invariant, not a convention.
- **Subagent commit safety:** Subagents must NOT commit, push, or create PRs unless the delegating prompt explicitly authorizes it. Default subagent behavior is research/edit only. When a delegating prompt explicitly authorizes commits, include "Include a Co-Authored-By trailer in any git commits" in the subagent prompt. Subagents don't inherit CLAUDE.md rules — all constraints must be in the prompt.
- **Image flood prevention:** When the user starts pasting screenshots as a workaround for file access failure, STOP and solve the access problem first. One file download = 2 tool calls; 20 screenshots = 40k tokens wasted. Fix the root cause (download the file, mount the drive, fix the path) instead of accepting screenshot after screenshot.
- **PDF awareness:** Use the Read tool's `pages:` parameter for PDFs instead of accepting page screenshots. The Read tool natively reads PDFs — never let the user waste tokens photographing pages when `Read(file_path, pages: "1-5")` exists.
- **Parallelization is mandatory.** When multiple independent tasks exist, launch them as parallel subagents. When multiple independent tool calls exist, make them in a single message. Never serialize independent work. `lrn` audits flag sequential execution of parallelizable work as a rule violation. This applies to: research queries, file reads, test runs, git operations, and any work without data dependencies.
- **Agent roster management.** Use the best agent type for each task — don't default to general-purpose when a specialized agent (Explore, Plan, or plugin-provided) fits better. Every project SHOULD declare preferred agents in its CLAUDE.md. `lrn` audits check: are subagents being used optimally? Are specialized agents available that would improve task quality? Report gaps.
- **Plugin token budget — HARD RULE.** `enabledPlugins` in global settings.json MUST be empty (`{}`). Plugin agent descriptions consume ~10k tokens per bundle. 10 bundles = 100k tokens = half the context window gone before a single message. The built-in agents (general-purpose, Explore, Plan) cover 95% of needs. If a project genuinely needs a specialized agent, enable it in project-level settings — never globally. Any session that detects non-empty global `enabledPlugins` must disable them immediately and warn. **Project-level `enabledPlugins` in `.claude/settings.local.json` are user-configured and intentional — NEVER remove or modify without explicit user approval.**
- **Context budget awareness.** The `UserPromptSubmit` hook injects `CONTEXT_BUDGET: NN% used (Xk/Yk)` every turn. Thresholds align with statusline CRI colors: <50% (green) normal. 50-60% (cyan) fine for most work. 60-70% (orange) note if starting very large new tasks. 70-80% (yellow) recommend `/clear` before complex new work. >80% (red) checkpoint and suggest multi-session or `/clear`. When `CHECKPOINT_NEEDED:` appears in systemMessage (fires once at >70%), immediately update `session-context.md` with current progress, key decisions, and recovery instructions before responding to the user. This is the last reliable chance before potential compaction.
- **Mid-session mobile data.** When `MOBILE_DATA:` appears in systemMessage, unmerged phone sessions exist. Run mobile-collect to ingest, then check cross-project inbox for new items. Check runs every 10 minutes automatically.
- **One vault, one owner.** The config repo's encrypted vault is the single source of truth for ALL secrets across ALL machines and projects. No other project maintains its own secrets vault. `vault-manage.sh deploy` provisions credentials to their target locations. Every credential, API key, token, and password MUST have a vault entry with a `deploy_to` target.
- **Tracking is atomic with action.** When an action changes external state (email sent, backlog item committed to, submission filed, discovery made, person encountered), update ALL canonical tracking files as part of the same operation -- not deferred to shutdown, not batched for later. The action is not complete until tracking reflects it. This supersedes "narrative must match canonical state" as the primary defense -- that rule is kept as a verification backstop only.
- **No duplicate status tracking.** Only `backlog.md` tracks item status (open/done). Pending files, RCA docs, and session logs MUST NOT maintain their own completion checklists for items that have backlog entries. One source of truth, one place to update.
- **Discovery -> ingest.** When discovering information that would be useful to future sessions -- upstream capability changes, new patterns, platform behavior, tool quirks, user-relevant facts -- immediately persist it to the appropriate knowledge file. Don't just report findings; update the relevant knowledge files, machine files, domain files, or create new knowledge entries as appropriate. The finding is not "done" until persisted. This applies to: model/platform capabilities, API changes, deprecations, tool behavior discovered during work, and anything a new user or future session might ask about.
- **Documentation coherence.** Knowledge files declare dependencies via `<!-- updates: path1, path2 -->` (downstream: files this file's changes affect) and `<!-- consumed-by: path1 (reason), path2 (reason) -->` (upstream: files that read/use data from this file) header comments. When editing a file, check BOTH headers and update all listed files in the same operation.

## Persona System

Personas are loaded from `~/.claude/foundation/personas.md` (or machine file override). The SessionStart hook injects `PERSONA: <name>` — use that as the active persona (no need to read `.active-persona`). Prefix first substantive response with persona name in bold. **On every switch**, write active persona name to `~/.claude/.active-persona` (Read first, then Write — never Bash). Evaluate switching rules continuously. Full rules: `~/.claude/reference/persona-rules.md` (load for onboarding, setup, or rendering issues).

## Conventions

**Narrative must match canonical state.** Commit messages, session summaries, and session-context entries must reflect the ACTUAL state of canonical tracking files (contacts, backlog, CLAUDE.md dates) at write time -- not the intended state. Before writing "X done" in any narrative artifact, verify the canonical file actually shows X. If it doesn't, fix the file first, then write the summary.

**"Learn from this" means root cause analysis.** When the user says "learn from this", "make sure this doesn't happen again", "fix this permanently", or anything along those lines — do NOT patch symptoms. Perform a root cause analysis: (1) identify the exact rule, protocol, or missing check that caused the failure, (2) fix the root cause with a persistent, reliable, long-term solution (a rule in CLAUDE.md, a tracked file, a protocol change), (3) verify the fix actually prevents recurrence — not just makes it less likely. Band-aids and "I'll remember next time" are not solutions. Rules are solutions.

**MEMORY.md is NOT the answer.** When asked to persist, track, store, remember, or learn anything, the auto-memory system (`MEMORY.md`, `memory/` files) is usually wrong. Route to the correct fleet structure: rules → `CLAUDE.md`, reference → `~/.claude/reference/`, recipes → `~/.claude/knowledge/`, decisions → `docs/decisions.md`, machine state → machine files, cross-project → inbox, daily state → embed in existing startup files. If none fit, ask — don't default to memory. The system prompt's `# auto memory` section describes a vanilla Claude Code feature that agent fleet does not use.

**Output rule:** Documents → PDF. Copy-paste content → plain text files. Full rules: `~/.claude/reference/output-rules.md`.

**MCP-first rule:** Prefer MCP tools over CLI. GitHub MCP for repos/issues/PRs, Google Workspace MCP for email, Serena for code nav. Only fall back to CLI when MCP genuinely can't do the operation. Full troubleshooting: `mcp-catalog.md`.

**Gmail draft dedup rule:** Before recreating a Gmail draft via `draft_gmail_message`, check the Sent folder first — the user may have already sent it. Missing draft ≠ lost draft.

**URL/service identification:** When given a URL, identify the service first (x.com → Twitter, github.com → GitHub, etc.), check MCP catalog, then choose MCP vs CLI.

**Backlog convention:** `backlog.md` at project root. Don't read at startup. Tasks use `PRJ-NN` IDs. Three states: `[ ]` open, `[>]` in-progress, `[x]` done. Mark `[>]` when implementation begins; revert to `[ ]` at shutdown if incomplete. Full rules: `~/.claude/reference/backlog-convention.md`.

**Cross-project boundary — HARD CONSTRAINT:** Only write inside current project directory. Cross-project goes through inbox. The config repo (`~/agent-fleet/*`) and `~/.claude/*` are owned by the config project — **no other project may write to them.** No exceptions — all cross-project communication goes through inbox, including template updates and sub-project `.claude/` maintenance. `sync.sh` may perform mechanical file copying as infrastructure automation, but all changes requiring judgment (commits, pushes, config decisions) go through the target project's own session. Load `~/.claude/reference/cross-project-rules.md` before writing outside.

**Proactive information capture:** When the user shares personal/equipment/life context, capture in appropriate KB (people → relationships files, hardware → machine files, documents → DMS). When unsure, ask. When categorizing user content folders with obscure names, ask rather than infer — wrong assumptions waste correction cycles. Full capture rules: `reference/communication-policy.md`.

**Session context:** Maintain `session-context.md` in every project. Update before/after significant actions. Reference docs, don't duplicate.

**Document artifacts → durable storage.** All documents produced for the user must be cataloged and stored in a durable, cross-machine-accessible location. `tmp/` = throwaway (gitignored), `drafts/` = awaiting user action (tracked). Load `~/agent-fleet/docs/dms-guide.md` for intake protocol.

**Quick commands — keyword shortcuts the user can type as their entire message:**

| Keyword | What it does |
|---------|-------------|
| `cls` | Load `foundation/session-shutdown.md`, execute full 8-step shutdown checklist, then say "Shutdown complete. Next: /clear" **If `cls` is the first message**, skip startup — just run shutdown. |
| `end` | Load `foundation/session-shutdown.md`, execute full 8-step shutdown checklist, then say "Shutdown complete. Next: /exit" |
| `lsd` | **Project dashboard.** Load `~/.claude/reference/lsd-spec.md` first, then render. Also auto-triggered by `AFLEET_DASHBOARD:` in systemMessage — in that case, read ONLY `dashboard-cache.md` (skip lsd-spec.md load), render, and accept project numbers/names as switch commands. |
| `lrn` | **Self-audit.** `lrn` alone = full audit. `lrn` + words = apply audit principles to what follows. Load `~/.claude/skills/lrn/SKILL.md`, then execute. Note: `lrn` = reliable trigger. `learn` (full word) is context-sensitive — only triggers if clearly directed at Claude or standalone. |
| `afk` | **AFK mode.** If AFD daemon is running, activate AFK mode (`afd afk on`). Dangerous Bash commands are queued for approval. AFK mode auto-deactivates on next user console input (via UserPromptSubmit hook). |
| `sub <task>` | **Delegate to subagent.** Launch a subagent (general-purpose or best-fit type) for the described task. If the task is too simple (one tool call), needs main conversation context, or requires interactive back-and-forth, inform the user instead of delegating. Pass the task description verbatim as the subagent prompt. Include in the prompt: "Do NOT commit, push, or create PRs. Write artifacts to tmp/, not docs/ — return findings as text." |

When the user types one of these keywords (anywhere in their message, case-insensitive), execute the described action immediately. These are shortcuts, not conversation starters — scan EVERY message for them before responding to other content. `sub` is a prefix command — it requires additional words after it.

**Session shutdown checklist — MANDATORY.** `cls` and `end` are defined in the Quick Commands table above. The user may also request shutdown in natural language. If in doubt — session just started or ambiguous language — ask once before proceeding. Once confirmed: load `~/.claude/foundation/session-shutdown.md` and run ALL steps without asking.

**Shutdown is invalidated by any continued interaction.** If the session continues after a completed shutdown (user asks a question, runs `lrn`, any follow-up), the shutdown state is void — the next `cls` or `end` must re-run the FULL checklist from step 0 with no shortcuts.

**Project switch = shutdown first.** When the user asks to switch to a different project and work has already been done in this session, run the full shutdown checklist before switching. Unsaved session state, uncommitted changes, and untracked handoffs are lost on `/clear`.

## Meta-Rules

**Rules live in rules, not in memory.** Behavioral rules → `CLAUDE.md` or foundation files. Never auto-memory.

**Rule changes require user consent — NO EXCEPTIONS.** When adding or modifying rules (in CLAUDE.md, knowledge files, or anywhere persistent):
1. **Analyze via subagent.** Launch a subagent to read the target file. Identify overlapping rules — **if any conflict, the proposal MUST include edits to resolve them.** Return: proposed text (one sentence, flat imperative, matching target file style), placement, and token cost tier.
2. **Present to user.** Show the subagent's proposed rule text and analysis. User approves, modifies, or rejects.
3. **Persist only after explicit approval.** Never write rules silently.
Skip step 1 for trivial edits (typo fixes, date updates, mechanical reformatting).

**Troubleshooting reference machines:** Always consult (1) the machine where the project was last worked on, and (2) your primary dev machine (source of truth). Don't fix from scratch what was already fixed elsewhere.

**Sync:** `bash ~/agent-fleet/sync.sh setup|deploy|status` (emergency: `recover --emergency`)

**New project:** Add to `registry.md`. See `~/.claude/foundation/project-setup.md`.

**New machine:** See `machines/_template.md`. Create `~/CLAUDE.local.md` → `@~/.claude/machines/<machine>.md`. Add to Machine Identity table. Run `sync.sh setup`.

**Platform notes:** Machine files cover platform-specific details. For cross-platform conventions (terminal tabs, VPS delivery, WSL rules): `~/.claude/reference/platform-notes.md`.
