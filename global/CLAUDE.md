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

**MANDATORY — NEVER SKIP.** Complete ALL steps before doing ANY user task. The user's first message often IS the trigger for startup — do not treat it as reason to skip loading. Even if the user asks something urgent, load first, then respond. A 30-second startup is always acceptable; lost context from skipping is not. **Exception:** When the SessionStart hook injects `AFLEET_DASHBOARD:` in systemMessage, follow those instructions instead — defer startup until the user gives a non-dashboard command.

**Auto-loaded via @import** (no action needed — loaded before you see this):
- `user-profile.md` — who the user is
- `session-protocol.md` — session context persistence rules
- `personas.md` — default personas (machine files can override)
- Machine file — via `CLAUDE.local.md` (machine-specific, not synced)

**Manual steps — execute in order:**

0. **ALWAYS check for remote changes — BEFORE reading any files.** Run `bash ~/agent-fleet/setup/scripts/git-sync-check.sh --pull <project-dir>` (pass the project directory as an argument — the script accepts an optional path). This fetches, reports incoming changes, and fast-forward pulls if behind. If it reports changes, re-read affected files. If it fails (diverged, merge conflict), resolve before proceeding. This applies to EVERY project, EVERY session, no exceptions. Reading stale files leads to wrong context, missed tasks, and wasted work.

1. **ALWAYS read cross-project inbox:** `~/agent-fleet/cross-project/inbox.md` — pick up tasks for this project AND its child projects. Use the `Parent` column in `registry.md` to determine parent-child relationships. Example: when working in a parent project, also flag tasks targeting child projects. Report child project tasks to the user but don't delete them — the child project session handles that. This is the cross-device task passing mechanism (mobile/VPS/PC all sync via git).

2. **Read `next-session-task.md`** (if exists, `task: true`) — previous session's handoff. Read the `file:` it points to.

3. **Read the project's `CLAUDE.md`** (manifest) — it declares what domains to load

4. **Read the project's `session-context.md`** (if exists) — current state and active tasks

5. **Follow the manifest's Knowledge Loading table** — load only the listed domain files

6. **Conditional loading (do NOT load unless triggered):**

   | Trigger | File |
   |---------|------|
   | `.setup-pending` exists (first run) | `foundation/first-run-refinement.md` |
   | MCP issue, auth, first MCP use | `reference/mcp-catalog.md` |
   | New/unconfigured project | `foundation/project-setup.md` |
   | Roster changes | `foundation/roster-management.md` |
   | Code project using Serena | `reference/serena.md` |
   | WSL troubleshooting | `reference/wsl-environment.md` |
   | Subagent permission failures | `reference/permissions.md` |
   | Cross-project coordination | `foundation/cross-project-sync.md` |
   | CLI tool usage, installed software | `reference/system-tools.md` |
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
   | Email drafts, social posts, formal correspondence | `reference/communication-policy.md` |
   | Document management, catalog | `~/agent-fleet/docs/dms-guide.md` |
   | Audit, self-audit, meta-audit | `knowledge/audit-protocol.md` |
   | `lrn` command issued | `knowledge/learn-protocol.md` |
   | YouTube tabs (save/list/open) | Run `bash ~/agent-fleet/setup/scripts/youtube-tabs.sh save\|list\|open [query]` — no file to load, just invoke the script directly |
   | Cross-project navigation, project switching | `reference/cross-project-nav.md` |
   | Statusline editing, GPI, statusline deployment | `knowledge/statusline-ops.md` |
   | Konsole tabs, qdbus, terminal tab operations | `knowledge/konsole-tabs.md` |
   | Filing GitHub issue on agent-fleet, `issue` command | `knowledge/fleet-issue-protocol.md` |
   | Session shutdown (`cls`, `end`, exit, shutdown) | `foundation/session-shutdown.md` |
   | Self-awareness, plugin recommendation, agent roster gaps, "can I do X?" capability questions | `knowledge/fleet-capabilities.md` |

   All paths relative to `~/.claude/` unless absolute. Do NOT load unless triggered.

7. **Check for project-specific knowledge**: `ls <project>/.claude/knowledge/` or `<project>/.claude/*.md`

8. **Do NOT load everything.** Only load what the manifest says + what's triggered by context.

## Indexes

- Foundation modules: `~/.claude/foundation/INDEX.md`
- Domain catalog: `~/.claude/domains/INDEX.md`
- **Full project catalog: `~/agent-fleet/registry.md`** — read on demand (project ops, `lsd`, or when user mentions other projects)

## Temporary Rules

<!-- Add temporary rules here. These are workarounds for known upstream issues that should be
     removed once the issue is fixed. Always include a tracking reference and removal criteria. -->

## Upstream Dependency Policy

**Daily version check is automated** by the SessionStart hook (Check 13.5). It runs `npm view` once per day (date-gated marker file) and surfaces update availability via systemMessage. No Claude action needed — just relay findings.

**First-session-of-day rule:** The first session each day handles triage (inbox, gmail, updates, handoffs). This consumes significant context. After completing triage, recommend the user run `/clear` to start a fresh working session with full context available. This is a recommendation, not a hard gate — the user decides.

For manual investigation: read `~/.claude/reference/upstream-dependencies.md`.

**Update policy — HARD RULE:** Before suggesting ANY upstream update, investigate the changelog and assess impact on our system (hooks, statusline, permissions, plugin compatibility). Present findings to the user. The user decides when to update. Never update silently or suggest "just update it."

## Development Rules

- **Task tracking is primary work.** Backlog items, session handoffs, inbox tasks, and "I'll note this" commitments are first-class deliverables. Execute immediately when stated — never defer. Anti-pattern: "I'll add a backlog item" → proceeds to other work → forgets.
- **Token cost awareness:** Every new feature must be evaluated for per-session token cost. Prefer bash/hook automation (0 LLM tokens) over behavioral rules loaded into CLAUDE.md (tokens every session). Plans must include a per-session token cost analysis table before approval.
- **No new files for daily state.** When a daily check needs persistent state (last scan date, last version check, last sync), embed it as a single line in a file that is ALREADY read at startup (session-context.md, CLAUDE.md metadata, etc.). Never create a separate tracking file — every extra file is an extra Read call per session. This is a recurring mistake pattern.
- **Recurring task "last checked" dates:** Before executing any recurring backlog task (marked "Recurs daily"), check its "Last checked: YYYY-MM-DD" marker. If already checked today on ANY machine, skip and use existing findings — don't spawn subagents to re-research. Only re-execute if: user explicitly requests it, or the task is classified as per-machine (e.g., installing an update vs researching a changelog). Research = once per fleet per day. Execution = per machine as needed.
- **TDD only:** All new code and features MUST follow test-driven development. Write failing tests first, then implement to make them pass. No implementation code without a corresponding test. This applies to bash scripts, config logic, and any testable behavior.
- **Never delete user files without explicit confirmation.** Especially bulk operations. Local duplicates may exist for a reason (playback copies, offline access, performance, workflow). Always ask before `rm -rf`, even if files appear redundant. "Verified elsewhere" ≠ "safe to delete locally."
- **No compound `cd` commands:** Use `git -C <path>` or absolute paths. Never `cd <dir> && <cmd>` — triggers security prompts.
- **No speculative interactive calls.** Never call user-facing prompts (passphrase dialogs, confirmations, GUI input) "just to test." Use them directly for the real operation. Handle errors after, not before. Each test call doubles user effort.
- **Long-running ops need tmux/nohup.** Operations expected to run >5 minutes MUST use `tmux new-session -d -s <name>` or `nohup`, never Claude Code's `run_in_background` (killed on `/exit`). Log to `/tmp/<name>.log`. Leave a pending file with tmux session name and check commands.
- **Check deployed config before editing.** Before editing any deployed config file (statusline, hooks, settings), verify which file the live config actually references (`settings.json`, `sync.sh status`). Never assume filename matches — deployed names may differ from repo names (e.g., `setup/config/statusline-command.sh` → `~/.claude/statusline-command.sh`).
- **Passphrase input MUST be masked.** Always use `ask-passphrase.sh` for credential prompts — it provides masked input via tkinter/zenity/kdialog/PowerShell WPF/read -s. Never improvise with unmasked alternatives (`InputBox`, plain `read`, etc.). If all masked paths fail, abort — don't fall back to plain text.
- **Bash permissions match first word only:** `Bash(npm:*)` only matches commands starting with `npm`. Never prefix with `VAR=x &&` or `sleep N &&`. See `knowledge/claude-code-permissions.md`.
- **Know your gitignore:** Before `git add`, verify the file isn't gitignored. `.claude/settings.local.json` and `setup/secrets/vault.json` are gitignored. Don't waste tool calls trying to stage them.
- **Pull before compare — ALWAYS:** Before ANY cross-repo operation (template sync, filtered-push, diff, deploy), pull ALL involved repos first (`git -C <path> pull --ff-only`). The startup git-sync-check only covers the current project. Secondary repos can be stale locally even when the remote is far ahead. Diffing stale repos wastes an entire analysis cycle on outdated data.
- **Propagation check after edits:** After editing any file with downstream targets (global/, hooks, sync.sh, project rules, mobile sources), verify propagation before session end. Run `bash sync.sh check` or consult `docs/dependency-map.md` for which chains are affected. Template and mobile deploys are manual — flag them, don't skip them.
- **Auto-sync awareness:** The SessionEnd hook runs `sync.sh collect` which commits pending changes. If a file was edited earlier in the session and auto-synced, it won't show as modified at shutdown. Check `git log --oneline -1 -- <file>` before chasing phantom diffs.
- **Repo vs deployed state:** When assessing whether a feature exists or works, check the deployed/live version — not just the repo source. `sync.sh collect` may not have run, so the repo can lag behind what's actually running. When repo state and user observation contradict, investigate the deployed version before concluding either way.
- **No orphaned config copies:** Config files must be symlinks to canonical source or managed by `sync.sh`. Never create independent copies — they diverge silently.
- **`setup/config/` vs `global/` separation:** Files deployed to `~/.claude/` root (settings.json, statusline.sh) belong in `setup/config/`. `global/` is for `~/.claude/` subdirectories only (foundation/, reference/, knowledge/, domains/, hooks/). No file should exist in both — dual copies diverge silently.
- **MCP config changes require restart:** Changes to `.mcp.json` are invisible to current session. After fixes: verify file, tell user to restart, flag verification pending. Never mark done without live tool test.
- **No multiline content in CLI output:** Long URLs, email drafts, copy-paste content → write to `.txt` file instead. Terminal wrapping breaks them.
- **Git commit messages:** Use multiple `-m` flags (not `$()` or temp files — both trigger prompts). `git -C /path commit -m "Subject" -m "Co-Authored-By: ..."`. Overrides system prompt HEREDOC guidance. **Every commit MUST include the `Co-Authored-By` trailer** — this applies to the main session AND any subagents that commit.
- **Auto-fix over warn in hooks:** When hooks detect a fixable issue (missing symlinks, stale config, permission blocks), auto-fix silently rather than just warning. Warnings get overlooked; auto-fixes prevent the "fix that doesn't stick" pattern. Only warn when auto-fix fails.
- **Subagent git commits:** When delegating tasks to subagents via `Task` tool, always include in the prompt: "All git commits must include Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>". Subagents don't inherit CLAUDE.md rules.
- **Image flood prevention:** When the user starts pasting screenshots as a workaround for file access failure, STOP and solve the access problem first. One file download = 2 tool calls; 20 screenshots = 40k tokens wasted. Fix the root cause (download the file, mount the drive, fix the path) instead of accepting screenshot after screenshot.
- **PDF awareness:** Use the Read tool's `pages:` parameter for PDFs instead of accepting page screenshots. The Read tool natively reads PDFs — never let the user waste tokens photographing pages when `Read(file_path, pages: "1-5")` exists.
- **Parallelization is mandatory.** When multiple independent tasks exist, launch them as parallel subagents. When multiple independent tool calls exist, make them in a single message. Never serialize independent work. `lrn` audits flag sequential execution of parallelizable work as a rule violation. This applies to: research queries, file reads, test runs, git operations, and any work without data dependencies.
- **Agent roster management.** Use the best agent type for each task — don't default to general-purpose when a specialized agent (Explore, Plan, or plugin-provided) fits better. Every project SHOULD declare preferred agents in its CLAUDE.md. `lrn` audits check: are subagents being used optimally? Are specialized agents available that would improve task quality? Report gaps.
- **Plugin token budget — HARD RULE.** `enabledPlugins` in global settings.json MUST be empty (`{}`). Plugin agent descriptions consume ~10k tokens per bundle. 10 bundles = 100k tokens = half the context window gone before a single message. The built-in agents (general-purpose, Explore, Plan) cover 95% of needs. If a project genuinely needs a specialized agent, enable it in project-level settings — never globally. Any session that detects non-empty global `enabledPlugins` must disable them immediately and warn.
- **Feature self-integrity.** The agent must know what features are configured (MCP servers, hooks, statusline, personas) and detect silent failures. `lrn` audits verify: are all MCP servers responding? Are hooks present at deployed paths? Are env vars injected? `config-check.sh` should catch failures, not the user. Load `knowledge/fleet-capabilities.md` when the agent needs to understand its own capabilities or recommend plugins/agents.
- **Context budget awareness.** The `UserPromptSubmit` hook injects `CONTEXT_BUDGET: NN% used (Xk/Yk)` every turn. Act on it: <50% normal. 50-70% warn if user starts large tasks. 70-85% recommend `/clear` before complex work. >85% checkpoint and suggest multi-session. Never ignore the budget.
- **One vault, one owner.** The config repo's encrypted vault is the single source of truth for ALL secrets across ALL machines and projects. No other project maintains its own secrets vault. `vault-manage.sh deploy` provisions credentials to their target locations. Every credential, API key, token, and password MUST have a vault entry with a `deploy_to` target.

## Persona System

Personas are loaded from `~/.claude/foundation/personas.md` (or machine file override). Prefix first substantive response with persona name in bold. **At session start and on every switch**, write active persona name to `~/.claude/.active-persona` (Read first, then Write — never Bash). Evaluate switching rules continuously. Full rules: `~/.claude/reference/persona-rules.md` (load for onboarding, setup, or rendering issues).

## Conventions

**"Learn from this" means root cause analysis.** When the user says "learn from this", "make sure this doesn't happen again", "fix this permanently", or anything along those lines — do NOT patch symptoms. Perform a root cause analysis: (1) identify the exact rule, protocol, or missing check that caused the failure, (2) fix the root cause with a persistent, reliable, long-term solution (a rule in CLAUDE.md, a tracked file, a protocol change), (3) verify the fix actually prevents recurrence — not just makes it less likely. Band-aids and "I'll remember next time" are not solutions. Rules are solutions.

**Auto-memory is WRONG for this setup.** Don't save rules/preferences to auto-memory. Rules → `CLAUDE.md`, decisions → `docs/decisions.md`, recipes → `~/.claude/knowledge/`, machine state → machine files, cross-project → inbox. "Always do X" = rule = `CLAUDE.md`. Memory's only valid use: temporary per-project orientation notes (<50 lines).

**Output rule:** Documents → PDF. Copy-paste content → plain text files. Full rules: `~/.claude/reference/output-rules.md`.

**MCP-first rule:** Prefer MCP tools over CLI. GitHub MCP for repos/issues/PRs, Google Workspace MCP for email, Serena for code nav. Only fall back to CLI when MCP genuinely can't do the operation. Full troubleshooting: `mcp-catalog.md`.

**Plain-language startup/shutdown messages:** Use human-readable status — "Last session shut down correctly" not "clean template, properly rotated".

**URL/service identification:** When given a URL, identify the service first (x.com → Twitter, github.com → GitHub, etc.), check MCP catalog, then choose MCP vs CLI.

**Backlog convention:** `backlog.md` at project root. Don't read at startup. Tasks use `PRJ-NN` IDs. Full format/IDs/prioritization rules: `~/.claude/reference/backlog-convention.md`.

**Cross-project boundary — HARD CONSTRAINT:** Only write inside current project directory. Cross-project goes through inbox. The config repo (`~/agent-fleet/*`) and `~/.claude/*` are owned by the config project — **no other project may write to them.** No exceptions — all cross-project communication goes through inbox, including template updates and sub-project `.claude/` maintenance. `sync.sh` may perform mechanical file copying as infrastructure automation, but all changes requiring judgment (commits, pushes, config decisions) go through the target project's own session. Load `~/.claude/reference/cross-project-rules.md` before writing outside.

**Proactive information capture:** When the user shares personal/equipment/life context, capture in appropriate KB (people → relationships files, hardware → machine files, documents → DMS). When unsure, ask. When categorizing user content folders with obscure names, ask rather than infer — wrong assumptions waste correction cycles. Full capture rules: `reference/communication-policy.md`.

**Session context:** Maintain `session-context.md` in every project. Update before/after significant actions. Reference docs, don't duplicate.

**Document artifacts → durable storage.** All documents produced for the user (drafts, letters, reports, PDFs — everything) must be cataloged and stored in a durable, cross-machine-accessible location. Project `tmp/` dirs are only for throwaway artifacts — never for documents the user needs to act on. Load `~/agent-fleet/docs/dms-guide.md` for intake protocol.

**Quick commands — keyword shortcuts the user can type as their entire message:**

| Keyword | What it does |
|---------|-------------|
| `cls` | Execute full 8-step shutdown checklist, then say "Shutdown complete — run /clear whenever you're ready." **If `cls` is the user's very first message**, skip the startup checklist entirely — the user is switching projects and doesn't need full context loading. Just run shutdown. Only run the startup checklist afterward if the user stays in the current project (i.e., sends a follow-up task instead of `/clear`). |
| `end` | Execute full 8-step shutdown checklist, then say "Shutdown complete — you can exit now." |
| `lsd` | **Project dashboard.** Load `~/.claude/reference/lsd-spec.md` first, then render. Also auto-triggered by `AFLEET_DASHBOARD:` in systemMessage — in that case, read ONLY `dashboard-cache.md` (skip lsd-spec.md load), render, and accept project numbers/names as switch commands. |
| `lrn` | **Self-audit.** `lrn` alone = full self-audit protocol. Load `~/.claude/knowledge/learn-protocol.md`, then execute. `lrn` + additional words = do what seems most wise in context, applying lrn protocol principles as defaults unless the words direct otherwise. Free-form — could be a topic, an exclusion, a complex directive. Use judgment. Note: only `lrn` (abbreviation) is a reliable standalone trigger. `learn` as a full English word is context-sensitive — only treat as audit trigger if clearly directed at Claude ("learn from this") or used alone with no other context. When ambiguous, ask. |
| `lrnd` | **Self-audit + shutdown.** Run `lrn` first (wait for results, present findings, apply fixes), then execute `end` (full 8-step shutdown checklist). Sequential — shutdown only starts after audit is complete and fixes applied. |
| `sub <task>` | **Delegate to subagent.** Launch a subagent (general-purpose or best-fit type) for the described task. If the task is too simple (one tool call), needs main conversation context, or requires interactive back-and-forth, inform the user instead of delegating. Pass the task description verbatim as the subagent prompt. Include in the prompt: "All git commits must include Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>". |

When the user types one of these keywords (alone, case-insensitive), execute the described action immediately without asking for confirmation. These are shortcuts, not conversation starters. `sub` is a prefix command — it requires additional words after it.

**Session shutdown checklist — MANDATORY.** When the user says "prepare for shutdown", "exit", "auto-compact restart", `cls`, `end`, or anything suggesting session end → load `~/.claude/foundation/session-shutdown.md` and run ALL steps, without asking. No exceptions. No asking "want me to commit?" — just do it.

## Meta-Rules

**Rules live in rules, not in memory.** Behavioral rules → `CLAUDE.md` or foundation files. Never auto-memory.

**Rule changes require user consent.** When adding or modifying rules (in CLAUDE.md, knowledge files, or anywhere persistent), ALWAYS present proposed rules to the user and only persist after explicit approval. Never write rules silently.

**Troubleshooting reference machines:** Always consult (1) the machine where the project was last worked on, and (2) your primary dev machine (source of truth). Don't fix from scratch what was already fixed elsewhere.

**Sync:** `bash ~/agent-fleet/sync.sh setup|deploy|collect|status`

**New project:** Add to `registry.md`. See `~/.claude/foundation/project-setup.md`.

**New machine:** See `machines/_template.md`. Create `~/CLAUDE.local.md` → `@~/.claude/machines/<machine>.md`. Add to Machine Identity table. Run `sync.sh setup`.

**Platform notes:** Machine files cover platform-specific details. For cross-platform conventions (terminal tabs, VPS delivery, WSL rules): `~/.claude/reference/platform-notes.md`.
