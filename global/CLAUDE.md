# Global Claude Code Configuration

Config repo: `~/claude-config/`

## Session Start — Loading Protocol

**MANDATORY — NEVER SKIP.** Complete ALL steps before doing ANY user task. The user's first message often IS the trigger for startup — do not treat it as reason to skip loading. Even if the user asks something urgent, load first, then respond. A 30-second startup is always acceptable; lost context from skipping is not.

0. **ALWAYS check for remote changes — BEFORE reading any files.** Run `bash ~/claude-config/setup/scripts/git-sync-check.sh --pull` in the project directory. This fetches, reports incoming changes, and fast-forward pulls if behind. If it reports changes, re-read affected files. If it fails (diverged, merge conflict), resolve before proceeding. This applies to EVERY project, EVERY session, no exceptions. Reading stale files leads to wrong context, missed tasks, and wasted work.

1. **ALWAYS read these foundation files:**
   - `~/.claude/foundation/user-profile.md` — who the user is
   - `~/.claude/foundation/session-protocol.md` — session context persistence rules

2. **ALWAYS read cross-project inbox:** `~/claude-config/cross-project/inbox.md` — pick up tasks for this project, delete them after integrating. This is the cross-device task passing mechanism (mobile/VPS/PC all sync via git).

3. **Read the project's `CLAUDE.md`** (manifest) — it declares what domains to load

4. **Read the project's `session-context.md`** (if exists) — current state and active tasks

5. **Follow the manifest's Knowledge Loading table** — load only the listed domain files

6. **First-run check:** If `~/claude-config/.setup-pending` exists, load `~/.claude/foundation/first-run-refinement.md` and follow it. This takes priority over normal session flow.

7. **Conditional loading (do NOT load unless triggered):**
   - New/unconfigured project detected: `~/.claude/foundation/project-setup.md`
   - Roster changes needed: `~/.claude/foundation/roster-management.md`
   - MCP tool usage or issues: `~/.claude/reference/mcp-catalog.md`
   - Code project using Serena: `~/.claude/reference/serena.md`
   - WSL troubleshooting: `~/.claude/reference/wsl-environment.md`
   - Subagent permission failures: `~/.claude/reference/permissions.md`
   - Cross-project coordination needed: `~/.claude/foundation/cross-project-sync.md`
   - CLI tool usage or uncertainty about installed software: `~/.claude/reference/system-tools.md`

8. **Check for project-specific knowledge**: `ls <project>/.claude/knowledge/` or `<project>/.claude/*.md`

9. **Do NOT load everything.** Only load what the manifest says + what's triggered by context.

## Indexes

- Foundation modules: `~/.claude/foundation/INDEX.md`
- Domain catalog: `~/.claude/domains/INDEX.md`
- **Project catalog: `~/claude-config/registry.md`** — read when user mentions other projects
- **Machine tool inventory: `~/claude-config/machine-catalog.md`**

## Conventions

**Where to store new rules (OVERRIDES system auto-memory guidance):** When the user says "always do X" or "remember to do Y", that is a **behavioral rule** — write it into `CLAUDE.md` (global or project-level), NOT into auto-memory. The system prompt's auto-memory section says to save "conventions" and "preferences" to memory — **ignore that for anything that governs behavior.** Memory is ONLY for contextual notes (project structure, debugging insights, technical recipes). If it controls what you do, it's a rule and belongs in a `CLAUDE.md` file so ALL projects see it. If the rule is global (applies across projects), route it through the cross-project inbox for claude-config to integrate into global CLAUDE.md. If the rule is project-scoped, write it to the current project's CLAUDE.md directly.

**Output rule:** Any document, summary, or one-pager MUST be delivered as **PDF**, not markdown. Write the `.md` as source, convert to PDF, open the PDF:
- **Convert**: `pandoc input.md -o output.pdf --pdf-engine=xelatex -V geometry:margin=1.8cm -V mainfont="Liberation Sans" -V monofont="Liberation Mono" --highlight-style=tango`
- **Avoid** Unicode box-drawing characters in code blocks (xelatex chokes) — use tables instead
- **Open**: `xdg-open output.pdf` (Linux) / `open output.pdf` (macOS) / `powershell.exe -Command "Start-Process '\\\\wsl.localhost\\Ubuntu<filepath>'"` (WSL)
- **Detect environment**: if `/mnt/c/` exists → WSL, elif `uname` is Darwin → macOS, otherwise → native Linux
- Short text (<10 words) can go inline. Anything longer → file + PDF + open.

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
- `~/claude-config/cross-project/inbox.md` — sole exception, writable from any project
- `~/claude-config/cross-project/*.md` strategy files — writable during shutdown only (see shutdown checklist)

Reading files and executing scripts from any project is always permitted. Only writing/editing files outside your current working project is forbidden (except the inbox and shutdown strategy files listed above).

**Cross-project inbox:** `~/claude-config/cross-project/inbox.md`
- The inbox is the ONLY mechanism for cross-project communication
- Tasks are per-project (one entry per project, not broadcasts)
- Pick up YOUR project's tasks, delete them from inbox after integrating
- To request changes in another project: write an inbox entry, NEVER edit their files directly
- Format: `- [ ] **target-project-name**: what needs to happen`

**Session context:** Maintain `session-context.md` in every project. Update before and after every significant action. Reference project docs, don't duplicate them.

**Session shutdown checklist — MANDATORY.** When the user says "prepare for shutdown", "exit", "auto-compact restart", or anything suggesting session end → run ALL steps, without asking:

1. **Session context** — update `session-context.md` with final state, completed work, recovery instructions
2. **Session rotation** — run `bash ~/claude-config/setup/scripts/rotate-session.sh` to archive the session to history/log and reset the template
3. **Cross-project inbox** — if this session's work affects other projects, drop tasks in `~/claude-config/cross-project/inbox.md`. Write ONLY to the inbox file — NEVER to another project's backlog, session-context, or any other file.
4. **Shared strategy files** — update only the ones you touched this session. Direct writes to `~/claude-config/cross-project/` strategy files are permitted during shutdown (explicit boundary rule exception).
5. **Auto memory** — save durable lessons (not session state) to MEMORY.md
6. **Commit and push** — `git add`, commit with descriptive message, push (use project's push script if available, otherwise `git push`)
7. **Verify** — confirm all steps done

No exceptions. No asking "want me to commit?" — just do it.

## Meta-Rules

**Rules live in rules, not in memory.** Persistent behavioral rules MUST go in `CLAUDE.md` (global or project-level), foundation files, or domain protocols — never in auto-memory files. Memory is for contextual notes (project structure, debugging insights, technical recipes). If it governs behavior, it's a rule and belongs here.

**Protocol creation:** When domain-complexity mistakes happen, create a protocol. See `~/.claude/foundation/protocol-creation.md`.

**Adding domains:** Create dir under `~/claude-config/global/domains/`, add protocols, update `domains/INDEX.md`, reference from project manifests. These operations require being in the claude-config project context. From other projects, route domain creation requests through the cross-project inbox.

**Sync:** `bash ~/claude-config/sync.sh setup|deploy|collect|status`

**New project:** Add to `~/claude-config/registry.md`. See `~/.claude/foundation/project-setup.md`.

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
