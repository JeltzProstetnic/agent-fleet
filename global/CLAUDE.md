# Global Claude Code Configuration

Config repo: `~/claude-config/`

## Session Start — Loading Protocol

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

**Output rule:** Any document, summary, or one-pager MUST be delivered as **PDF**, not markdown. Write the `.md` as source, convert to PDF, open the PDF:
- **Convert**: `pandoc input.md -o output.pdf --pdf-engine=xelatex -V geometry:margin=1.8cm -V mainfont="Liberation Sans" -V monofont="Liberation Mono" --highlight-style=tango`
- **Avoid** Unicode box-drawing characters in code blocks (xelatex chokes) — use tables instead
- **Open**: `xdg-open output.pdf` (Linux) / `open output.pdf` (macOS) / `powershell.exe -Command "Start-Process '\\\\wsl.localhost\\Ubuntu<filepath>'"` (WSL)
- **Detect environment**: if `/mnt/c/` exists → WSL, elif `uname` is Darwin → macOS, otherwise → native Linux
- Short text (<10 words) can go inline. Anything longer → file + PDF + open.

**Backlog convention:** Every project has `backlog.md` at root. Do NOT read at session start — only when active tasks are done or user asks.

**Cross-project inbox:** `~/claude-config/cross-project/inbox.md`
- Tasks are per-project (one entry per project, not broadcasts)
- Pick up YOUR project's tasks, delete them from inbox after integrating
- NEVER write directly into another project's files — drop a message in the inbox instead

**Session context:** Maintain `session-context.md` in every project. Update before and after every significant action.

## Meta-Rules

**Rules live in rules, not in memory.** Persistent behavioral rules MUST go in `CLAUDE.md` (global or project-level), foundation files, or domain protocols — never in auto-memory files. Memory is for contextual notes (project structure, debugging insights, technical recipes). If it governs behavior, it's a rule and belongs here.

**Protocol creation:** When domain-complexity mistakes happen, create a protocol. See `~/.claude/foundation/protocol-creation.md`.

**Adding domains:** Create dir under `~/claude-config/global/domains/`, add protocols, update `domains/INDEX.md`, reference from project manifests.

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
