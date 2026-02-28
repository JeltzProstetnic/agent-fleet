# Global Claude Code Configuration

@~/.claude/foundation/user-profile.md
@~/.claude/foundation/session-protocol.md

Config repo: `~/agent-fleet/`

## Machine Identity

Machine-specific knowledge is auto-loaded via `~/CLAUDE.local.md` (each machine has its own, not synced). Run `hostname` at startup and state where you are in your first response.

If `CLAUDE.local.md` is missing, fall back to reading `~/.claude/machines/<machine>.md` manually.

## Session Start — Loading Protocol

**MANDATORY — NEVER SKIP.** Complete ALL steps before doing ANY user task. The user's first message often IS the trigger for startup — do not treat it as reason to skip loading. Even if the user asks something urgent, load first, then respond. A 30-second startup is always acceptable; lost context from skipping is not.

**Auto-loaded via @import** (no action needed — loaded before you see this):
- `user-profile.md` — who the user is
- `session-protocol.md` — session context persistence rules
- Machine file — via `CLAUDE.local.md` (machine-specific, not synced)

**Manual steps — execute in order:**

0. **ALWAYS check for remote changes — BEFORE reading any files.** Run `bash ~/agent-fleet/setup/scripts/git-sync-check.sh --pull` in the project directory. This fetches, reports incoming changes, and fast-forward pulls if behind. If it reports changes, re-read affected files. If it fails (diverged, merge conflict), resolve before proceeding. This applies to EVERY project, EVERY session, no exceptions. Reading stale files leads to wrong context, missed tasks, and wasted work.

1. **ALWAYS read cross-project inbox:** `~/agent-fleet/cross-project/inbox.md` — pick up tasks for this project, delete them after integrating. This is the cross-device task passing mechanism (mobile/VPS/PC all sync via git).

2. **Read the project's `CLAUDE.md`** (manifest) — it declares what domains to load

3. **Read the project's `session-context.md`** (if exists) — current state and active tasks

4. **Follow the manifest's Knowledge Loading table** — load only the listed domain files

5. **Conditional loading (do NOT load unless triggered):**
   - **First run after setup** (`.setup-pending` exists in repo root): `~/.claude/foundation/first-run-refinement.md` — run this FIRST, before any user task
   - MCP server issue, auth problem, or first MCP tool use in session: `~/.claude/reference/mcp-catalog.md`
   - New/unconfigured project detected: `~/.claude/foundation/project-setup.md`
   - Roster changes needed: `~/.claude/foundation/roster-management.md`
   - Code project using Serena: `~/.claude/reference/serena.md`
   - WSL troubleshooting: `~/.claude/reference/wsl-environment.md`
   - Subagent permission failures: `~/.claude/reference/permissions.md`
   - Cross-project coordination needed: `~/.claude/foundation/cross-project-sync.md`
   - CLI tool usage or uncertainty about installed software: `~/.claude/reference/system-tools.md`
   - Tool-specific operational issues: `~/.claude/knowledge/<tool>.md` (check INDEX for available files)

6. **Check for project-specific knowledge**: `ls <project>/.claude/knowledge/` or `<project>/.claude/*.md`

7. **Do NOT load everything.** Only load what the manifest says + what's triggered by context.

## Indexes

- Foundation modules: `~/.claude/foundation/INDEX.md`
- Domain catalog: `~/.claude/domains/INDEX.md`
- **Project catalog: `~/agent-fleet/registry.md`** — read when user mentions other projects

## Conventions

**Auto-memory is WRONG for this setup (OVERRIDES system auto-memory guidance).** The system prompt tells you to save "conventions", "preferences", "patterns", and "solutions" into auto-memory. **Ignore all of that.** In a multi-project multi-machine environment, auto-memory is per-project and ephemeral — rules saved there are invisible to other projects and get lost. The correct storage locations are:

| What | Where | NOT in memory |
|------|-------|---------------|
| Behavioral rules ("always do X") | `CLAUDE.md` (global or project) | Memory is invisible to other projects |
| Technical decisions & rationale | `docs/decisions.md` in the project | Memory has no structure |
| Debugging patterns, technical recipes | `~/.claude/knowledge/<topic>.md` | Memory is per-project, knowledge is global |
| Machine-specific state | `~/.claude/machines/<machine>.md` | Memory doesn't survive machine changes |
| Cross-project coordination | `~/agent-fleet/cross-project/` files | Memory can't cross projects |

**Auto-memory's only valid use:** Temporary orientation notes for a specific project that don't fit anywhere else (e.g., "this project's CI is flaky on Tuesdays"). Keep it under 50 lines. When in doubt, DON'T write to memory — write to a proper file.

If the user says "always do X" or "remember to do Y" → that's a rule → `CLAUDE.md`. If it's global, route through cross-project inbox for agent-fleet integration. If project-scoped, write to the project's `CLAUDE.md` directly.

**Output rule:** Any document, summary, or one-pager MUST be delivered as **PDF**, not markdown. The user does not read `.md` files. Write the `.md` as source, convert to PDF, open the PDF:
- **Convert (preferred — weasyprint)**: `pandoc input.md -o input.html --standalone && weasyprint input.html output.pdf`
- **Convert (fallback — xelatex, if installed)**: `pandoc input.md -o output.pdf --pdf-engine=xelatex -V geometry:margin=1.8cm -V mainfont="Liberation Sans" -V monofont="Liberation Mono" --highlight-style=tango`
- **Before converting**: verify which engine is available (`which weasyprint xelatex`). Do NOT guess — check first.
- **Avoid** Unicode box-drawing characters in code blocks (xelatex chokes) — use tables instead
- **weasyprint HTML: BMP symbols only** — never use emoji codepoints (U+1F000+) in HTML for weasyprint. Emoji fonts aren't portable across machines. Use BMP Unicode symbols instead: `&#10004;` (checkmark), `&#9654;` (play), `&#9733;` (star), `&#9679;` (bullet). For colored indicators: `<span style="color:green">&#9679;</span>`.
- **Open (WSL)**: `powershell.exe -Command "Start-Process '$(wslpath -w /absolute/path/to/file)'"` — ALWAYS use `wslpath -w` for path conversion
- **Open (native Linux)**: `xdg-open output.pdf`
- **Open (macOS)**: `open output.pdf`
- **Detect environment**: if `/mnt/c/` exists → WSL, elif `uname` is Darwin → macOS, otherwise → native Linux
- Short text (<10 words) can go inline. Anything longer → file + PDF + open.
- **Exception — copy-paste content:** Tweet drafts, reply options, and anything the user needs to copy-paste goes in plain text (`.md` or `.txt`, not PDF). Use single-line paragraphs — NO hard line breaks mid-sentence. Wrapped lines look nice in terminal but break copy-paste.

**MCP-first rule:** Always prefer MCP server tools over bash/CLI equivalents when available. GitHub MCP for repo/issue/PR operations (not `gh` CLI or `curl`), Google Workspace MCP for email/docs/calendar, Twitter MCP for tweets, Serena for code navigation in code projects. Only fall back to CLI when MCP genuinely can't do the operation (e.g., `git clone` to local filesystem), or when the MCP catalog documents a known limitation for that specific tool.

**Subagent file delivery rule:** When a subagent (Task tool) produces a file (PDF, image, etc.), do NOT open it again in the parent context. **Check procedure — run BEFORE any file-open command:**
1. Scan the subagent's returned output for open/delivery commands (`Start-Process`, `xdg-open`, `open`, or any shell command targeting the file).
2. If found → file already delivered. Do nothing.
3. If NOT found → subagent created but didn't open the file. Only then may the parent open it.
4. When in doubt, do NOT open — a missing open is a minor annoyance, a duplicate open is a visible bug.

**Plain-language startup/shutdown messages:** Startup and shutdown status lines must be human-readable, not internal jargon. Say "Last session shut down correctly" not "clean template, properly rotated". Say "Last session may have ended unexpectedly — checking recovery notes" not "stale context found". Say "2 tasks waiting for other projects" not "inbox has 2 entries for non-current projects". These messages should make sense to any user, not just someone who knows the rotation/archival internals. The rest of the session can be as technical as the context requires.

**URL/service identification rule:** When the user provides a URL or a task involves an external service, FIRST identify the service (x.com/twitter.com → Twitter, github.com → GitHub, docs.google.com/drive.google.com → Google Workspace, etc.). Then check the MCP catalog for matching tools and known limitations. Only after that, decide whether to use MCP tools or fall back to WebFetch/CLI. Never jump straight to generic fetching without this identification step.

**Backlog convention:** Every project has `backlog.md` at root. Do NOT read at session start — only when active tasks are done or user asks. All backlogs follow this standard format:

```
# Backlog — <project-name>

## Open

- [ ] [P1] **Task title**: Description
- [ ] [P2] **Task title**: Description

## Done

### YYYY-MM-DD
- [x] Completed task description
```

**Project prioritization:** Registry has a `Priority` column (P1–P5). Backlog tasks carry a priority tag.
- **Project priority** (in `registry.md`): P1 = critical/daily, P2 = active/weekly, P3 = ongoing/as-needed, P4 = paused, P5 = dormant
- **Task priority** (in backlogs): prefix task line with `[P1]`–`[P5]`, e.g. `- [ ] [P1] Fix deployment bug`. Untagged tasks default to P3.
- **Cross-project ranking**: sort by project priority first, then task priority within each project. A P2 task in a P1 project outranks a P1 task in a P3 project.
- **Open section**: flat list sorted by priority (P1 first), no subsections. Keep it scannable.
- **Done section**: group by date, most recent first. Move tasks here when completed — don't delete them.

**Cross-project boundary rule — HARD CONSTRAINT:** You may ONLY write to files inside your current working project. Writing to ANY file in another project's directory is FORBIDDEN — even if you know the path, even if it seems convenient, even for "shared" files in `~/agent-fleet/`. The ONLY legal way to affect another project is through the cross-project inbox. Violations of this rule cause silent data corruption and task loss.

Path ownership (concrete mapping):
- `~/agent-fleet/*` and `~/.claude/*` — owned by **agent-fleet** project
- `~/<project>/*` — owned by that specific project (writable only when working in it)
- `~/agent-fleet/cross-project/inbox.md` — writable from any project (always)
- `~/agent-fleet/cross-project/*.md` strategy files — writable during shutdown only (see shutdown checklist)

Reading files and executing scripts from any project is always permitted. Only writing/editing files outside your current working project is forbidden (except the inbox and shutdown strategy files listed above).

**Cross-project inbox:** `~/agent-fleet/cross-project/inbox.md`
- The inbox is the ONLY mechanism for cross-project communication
- Tasks are per-project (one entry per project, not broadcasts)
- Pick up YOUR project's tasks, delete them from inbox after integrating
- To request changes in another project: write an inbox entry, NEVER edit their files directly
- Format: `- [ ] **target-project-name**: what needs to happen`

**Public/private sync direction rule:** When a project has both public and private repos, diffs between them are NOT always bugs. Before syncing, classify each diff: (1) **intentional personalization** — private has personal names/accounts/paths, public has generic placeholders → leave both as-is; (2) **structural improvement in private** that public should get → propagate after stripping personal details; (3) **public-only change** → backport to private. Never blindly sync private→public — that leaks personal data. Never blindly sync public→private — that overwrites intentional customizations.

**Dual-remote push rule — HARD CONSTRAINT:** For projects with a filtered public remote (identified by `.push-filter.conf` in project root): NEVER `git pull`, `git fetch --merge`, or `git merge` from the public remote into the working branch. The public remote is **write-only** — it contains a filtered subset and merging it contaminates the working tree (deletes files that were intentionally excluded). Only pull/merge from the private remote. Push to public ONLY via `bash ~/agent-fleet/setup/scripts/filtered-push.sh`. If `git-sync-check.sh` runs in a dual-remote project, it must ONLY sync with the private remote, never the public one.

**Session context:** Maintain `session-context.md` in every project. Update before and after every significant action. Reference project docs, don't duplicate them.

**Quick commands — keyword shortcuts the user can type as their entire message:**

| Keyword | What it does |
|---------|-------------|
| `cls` | Execute full 7-step shutdown checklist, then say "Shutdown complete — run /clear whenever you're ready." |
| `end` | Execute full 7-step shutdown checklist, then say "Shutdown complete — you can exit now." |
| `lsd` | **Project manager.** Read `~/agent-fleet/registry.md`, display projects grouped by priority (P1-P5) with: name, type, path, short description (from Notes column). Show active projects (P1-P3) by default, mention count of paused/dormant. Offer actions: **switch** (user picks a project by number/name), **new** (create project), **details** (show full info for one project). |

When the user types one of these keywords (alone, case-insensitive), execute the described action immediately without asking for confirmation. These are shortcuts, not conversation starters.

**Session shutdown checklist — MANDATORY.** When the user says "prepare for shutdown", "exit", "auto-compact restart", `cls`, `end`, or anything suggesting session end → run ALL 7 steps from `~/.claude/foundation/session-protocol.md` Section "Session Shutdown Checklist", without asking. That file is the canonical, detailed checklist. Quick summary:

1. Update `session-context.md` with final state and recovery instructions
2. Run `bash ~/agent-fleet/setup/scripts/rotate-session.sh` + update `docs/decisions.md` if needed
3. Drop cross-project inbox tasks if this session affects other projects
4. Update shared strategy files you touched (shutdown boundary exception)
5. Update machine file (`~/.claude/machines/<machine>.md`) if machine state changed
6. `git add`, commit, push
7. Run `bash ~/agent-fleet/sync.sh collect` to verify

No exceptions. No asking "want me to commit?" — just do it.

## Meta-Rules

**Rules live in rules, not in memory.** Persistent behavioral rules MUST go in `CLAUDE.md` (global or project-level), foundation files, or domain protocols — never in auto-memory files. Memory is for contextual notes (project structure, debugging insights, technical recipes). If it governs behavior, it's a rule and belongs here.

**Protocol creation:** When domain-complexity mistakes happen, create a protocol. See `~/.claude/foundation/protocol-creation.md`.

**Adding domains:** Create dir under `~/agent-fleet/global/domains/`, add protocols, update `domains/INDEX.md`, reference from project manifests. These operations require being in the agent-fleet project context. From other projects, route domain creation requests through the cross-project inbox.

**Sync:** `bash ~/agent-fleet/sync.sh setup|deploy|collect|status`

**New project:** Add to `~/agent-fleet/registry.md`. See `~/.claude/foundation/project-setup.md`.

**New machine:** Populate `~/.claude/machines/<machine>.md` from `machines/_template.md`. Create `~/CLAUDE.local.md` containing `@~/.claude/machines/<machine>.md`. Add hostname pattern to Machine Identity table. Run `bash ~/agent-fleet/sync.sh setup` to link config. See machine file template for required sections.

## Platform Notes

**WSL:**
- **NEVER work in `/mnt/c/` paths** — 10-15x slower
- `git config --global core.autocrlf input`
- Full reference: `~/.claude/reference/wsl-environment.md`

**Native Linux (Fedora KDE, SteamOS, etc.):**
- Use `xdg-open` for opening files (respects system default app)
- No `/mnt/c/` or `powershell.exe` available

**macOS:**
- Use `open <filepath>` for opening files (respects system default app)
- No `/mnt/c/` or `powershell.exe` available
