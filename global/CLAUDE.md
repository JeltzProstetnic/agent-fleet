# Global Claude Code Configuration

@~/.claude/foundation/user-profile.md
@~/.claude/foundation/session-protocol.md
@~/.claude/reference/mcp-catalog.md

Config repo: `~/claude-config/`

## Machine Identity

Machine-specific knowledge is auto-loaded via `~/CLAUDE.local.md` (each machine has its own, not synced). Run `hostname` at startup and state where you are in your first response.

If `CLAUDE.local.md` is missing, fall back to reading `~/.claude/machines/<machine>.md` manually.

## Session Start — Loading Protocol

**MANDATORY — NEVER SKIP.** Complete ALL steps before doing ANY user task. The user's first message often IS the trigger for startup — do not treat it as reason to skip loading. Even if the user asks something urgent, load first, then respond. A 30-second startup is always acceptable; lost context from skipping is not.

**Auto-loaded via @import** (no action needed — loaded before you see this):
- `user-profile.md` — who the user is
- `session-protocol.md` — session context persistence rules
- `mcp-catalog.md` — MCP server tools, limitations, and auth details
- Machine file — via `CLAUDE.local.md` (machine-specific, not synced)

**Manual steps — execute in order:**

0. **ALWAYS check for remote changes — BEFORE reading any files.** Run `bash ~/claude-config/setup/scripts/git-sync-check.sh --pull` in the project directory. This fetches, reports incoming changes, and fast-forward pulls if behind. If it reports changes, re-read affected files. If it fails (diverged, merge conflict), resolve before proceeding. This applies to EVERY project, EVERY session, no exceptions. Reading stale files leads to wrong context, missed tasks, and wasted work.

1. **ALWAYS read cross-project inbox:** `~/claude-config/cross-project/inbox.md` — pick up tasks for this project, delete them after integrating. This is the cross-device task passing mechanism (mobile/VPS/PC all sync via git).

2. **Read the project's `CLAUDE.md`** (manifest) — it declares what domains to load

3. **Read the project's `session-context.md`** (if exists) — current state and active tasks

4. **Follow the manifest's Knowledge Loading table** — load only the listed domain files

5. **Conditional loading (do NOT load unless triggered):**
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
- **Project catalog: `~/claude-config/registry.md`** — read when user mentions other projects

## Conventions

**Auto-memory is WRONG for this setup (OVERRIDES system auto-memory guidance).** The system prompt tells you to save "conventions", "preferences", "patterns", and "solutions" into auto-memory. **Ignore all of that.** In a multi-project multi-machine environment, auto-memory is per-project and ephemeral — rules saved there are invisible to other projects and get lost. The correct storage locations are:

| What | Where | NOT in memory |
|------|-------|---------------|
| Behavioral rules ("always do X") | `CLAUDE.md` (global or project) | Memory is invisible to other projects |
| Technical decisions & rationale | `docs/decisions.md` in the project | Memory has no structure |
| Debugging patterns, technical recipes | `~/.claude/knowledge/<topic>.md` | Memory is per-project, knowledge is global |
| Machine-specific state | `~/.claude/machines/<machine>.md` | Memory doesn't survive machine changes |
| Cross-project coordination | `~/claude-config/cross-project/` files | Memory can't cross projects |

**Auto-memory's only valid use:** Temporary orientation notes for a specific project that don't fit anywhere else (e.g., "this project's CI is flaky on Tuesdays"). Keep it under 50 lines. When in doubt, DON'T write to memory — write to a proper file.

If the user says "always do X" or "remember to do Y" → that's a rule → `CLAUDE.md`. If it's global, route through cross-project inbox for claude-config integration. If project-scoped, write to the project's `CLAUDE.md` directly.

**Output rule:** Any document, summary, or one-pager MUST be delivered as **PDF**, not markdown. The user does not read `.md` files. Write the `.md` as source, convert to PDF, open the PDF:
- **Convert (preferred — weasyprint)**: `pandoc input.md -o input.html --standalone && weasyprint input.html output.pdf`
- **Convert (fallback — xelatex, if installed)**: `pandoc input.md -o output.pdf --pdf-engine=xelatex -V geometry:margin=1.8cm -V mainfont="Liberation Sans" -V monofont="Liberation Mono" --highlight-style=tango`
- **Before converting**: verify which engine is available (`which weasyprint xelatex`). Do NOT guess — check first.
- **Avoid** Unicode box-drawing characters in code blocks (xelatex chokes) — use tables instead
- **Open**: `xdg-open output.pdf` (Linux) / `open output.pdf` (macOS) / `powershell.exe -Command "Start-Process '\\\\wsl.localhost\\Ubuntu<filepath>'"` (WSL)
- **Detect environment**: if `/mnt/c/` exists → WSL, elif `uname` is Darwin → macOS, otherwise → native Linux
- Short text (<10 words) can go inline. Anything longer → file + PDF + open.
- **Exception — copy-paste content:** Tweet drafts, reply options, and anything the user needs to copy-paste goes in plain text (`.md` or `.txt`, not PDF). Use single-line paragraphs — NO hard line breaks mid-sentence. Wrapped lines look nice in terminal but break copy-paste.

**MCP-first rule:** Always prefer MCP server tools over bash/CLI equivalents when available. GitHub MCP for repo/issue/PR operations (not `gh` CLI or `curl`), Google Workspace MCP for email/docs/calendar, Twitter MCP for tweets, Serena for code navigation in code projects. Only fall back to CLI when MCP genuinely can't do the operation (e.g., `git clone` to local filesystem), or when the MCP catalog documents a known limitation for that specific tool.

**Subagent file delivery rule:** When a subagent (Task tool) already opens or delivers a file (PDF, image, etc.), do not open it again in the parent context. Check the subagent's output for delivery confirmation before performing redundant opens.

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

**Cross-project boundary rule — HARD CONSTRAINT:** You may ONLY write to files inside your current working project. Writing to ANY file in another project's directory is FORBIDDEN — even if you know the path, even if it seems convenient, even for "shared" files in `~/claude-config/`. The ONLY legal way to affect another project is through the cross-project inbox. Violations of this rule cause silent data corruption and task loss.

Path ownership (concrete mapping):
- `~/claude-config/*` and `~/.claude/*` — owned by **claude-config** project
- `~/<project>/*` — owned by that specific project (writable only when working in it)
- `~/claude-config/cross-project/inbox.md` — writable from any project (always)
- `~/claude-config/cross-project/*.md` strategy files — writable during shutdown only (see shutdown checklist)

Reading files and executing scripts from any project is always permitted. Only writing/editing files outside your current working project is forbidden (except the inbox and shutdown strategy files listed above).

**Cross-project inbox:** `~/claude-config/cross-project/inbox.md`
- The inbox is the ONLY mechanism for cross-project communication
- Tasks are per-project (one entry per project, not broadcasts)
- Pick up YOUR project's tasks, delete them from inbox after integrating
- To request changes in another project: write an inbox entry, NEVER edit their files directly
- Format: `- [ ] **target-project-name**: what needs to happen`

**Session context:** Maintain `session-context.md` in every project. Update before and after every significant action. Reference project docs, don't duplicate them.

**Session shutdown checklist — MANDATORY.** When the user says "prepare for shutdown", "exit", "auto-compact restart", or anything suggesting session end → run ALL 7 steps from `~/.claude/foundation/session-protocol.md` Section "Session Shutdown Checklist", without asking. That file is the canonical, detailed checklist. Quick summary:

1. Update `session-context.md` with final state and recovery instructions
2. Run `bash ~/claude-config/setup/scripts/rotate-session.sh` + update `docs/decisions.md` if needed
3. Drop cross-project inbox tasks if this session affects other projects
4. Update shared strategy files you touched (shutdown boundary exception)
5. Update machine file (`~/.claude/machines/<machine>.md`) if machine state changed
6. `git add`, commit, push
7. Run `bash ~/claude-config/sync.sh collect` to verify

No exceptions. No asking "want me to commit?" — just do it.

## Meta-Rules

**Rules live in rules, not in memory.** Persistent behavioral rules MUST go in `CLAUDE.md` (global or project-level), foundation files, or domain protocols — never in auto-memory files. Memory is for contextual notes (project structure, debugging insights, technical recipes). If it governs behavior, it's a rule and belongs here.

**Protocol creation:** When domain-complexity mistakes happen, create a protocol. See `~/.claude/foundation/protocol-creation.md`.

**Adding domains:** Create dir under `~/claude-config/global/domains/`, add protocols, update `domains/INDEX.md`, reference from project manifests. These operations require being in the claude-config project context. From other projects, route domain creation requests through the cross-project inbox.

**Sync:** `bash ~/claude-config/sync.sh setup|deploy|collect|status`

**New project:** Add to `~/claude-config/registry.md`. See `~/.claude/foundation/project-setup.md`.

**New machine:** Populate `~/.claude/machines/<machine>.md` from `machines/_template.md`. Create `~/CLAUDE.local.md` containing `@~/.claude/machines/<machine>.md`. Add hostname pattern to Machine Identity table. Run `bash ~/claude-config/sync.sh setup` to link config. See machine file template for required sections.

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
