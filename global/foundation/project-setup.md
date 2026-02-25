# New Project Detection & Setup Protocol

## How to detect "new project"

A project is considered new (and triggers full roster + skill discovery) when **any** of these are true:

| Signal | Check |
|--------|-------|
| **Empty or near-empty directory** | `ls` shows no files, or only a README / LICENSE / .gitignore |
| **No `.claude/` directory** | No agents, no skills, no project rules yet |
| **No `session-context.md`** | Never been worked on by Claude before |
| **User explicitly says so** | "Create a new project", "Let's start a new project for X" |
| **Freshly cloned repo with no roster** | Has code but no `.claude/agents/` or `.claude/skills/` |

**NOT new** (skip full discovery, do normal session-start roster check):
- Has `.claude/agents/` with files in it
- Has `session-context.md` with prior session history

## New Project Setup Steps

1. **Understand the project** — read any existing files, ask the user about goals, tech stack, phases
2. **Select subagents** — browse categories, pick 4-8 agents matching the project domain
3. **Run skill discovery** — browse skill catalog, select relevant skills for the project type
4. **Configure MCP servers** — determine which servers are needed (code → Serena; GitHub repo → GitHub MCP; etc.)
5. **Set up roster** — create `.claude/agents/`, `.claude/skills/`, copy selected files
6. **Create session-context.md** — initial project state
7. **Add project to registry**: update `~/claude-config/registry.md`
8. **Tell the user**: "Roster set up with N agents and M skills. Please restart to load them."

---

## Project Manifest Template

Every project's `CLAUDE.md` follows this format:

```
# <Project Name>

<One paragraph: what this project is, current phase, tech stack>

## Knowledge Loading

| Domain | Path | Load when... |
|--------|------|-------------|
| <domain> | `~/.claude/domains/<domain>/<file>.md` | <condition> |

## Reference (load on demand, not at start)

- MCP catalog: `~/.claude/reference/mcp-catalog.md`
- Serena: `~/.claude/reference/serena.md` (if code project)

## Active Roster

- Agents: <list or "none">
- Skills: <list or "none">

## Project-Specific Knowledge

- `.claude/knowledge/<file>.md` — project-specific protocols
- `backlog.md` — project backlog (read when active TODOs are done)
```
