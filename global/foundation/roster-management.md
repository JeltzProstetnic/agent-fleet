# Roster Management — Agents, Skills, MCP Servers

**At every session start, and whenever the work context changes significantly during a session, check that the active roster of agents, skills, and MCP servers fits the current project, phase, and task.**

For new project setup, see `foundation/project-setup.md`.

---

## 1. The Roster Concept

A project's "roster" is the set of active tooling loaded at startup:

| Component | Directory | What it does | Restart needed? |
|-----------|-----------|-------------|-----------------|
| **Subagents** | `<project>/.claude/agents/` | Isolated specialist execution contexts (own model + tools) | Yes |
| **Skills** | `<project>/.claude/skills/` or `~/.claude/skills/` | Procedural knowledge loaded into current agent's context | Yes |
| **MCP Servers** | `<project>/.mcp.json` or `~/.mcp.json` | External tool integrations (GitHub, Serena, etc.) | Yes |

All three follow the same principle: **load only what's needed for the current work, unload what isn't.** Context waste from irrelevant tooling descriptions degrades performance.

---

## 2. Session-Start Roster Check — MANDATORY

At every session start, before doing any work:

### Step 1: Read session context
Read `session-context.md` to understand the current project phase and active task.

### Step 2: Assess current roster
```bash
# What's loaded?
ls <project>/.claude/agents/ 2>/dev/null   # Subagents
ls <project>/.claude/skills/ 2>/dev/null   # Skills
cat <project>/.mcp.json 2>/dev/null        # MCP servers
```

### Step 3: Compare roster to session needs
Ask yourself:
- Does the session goal match the loaded agents? (e.g., publication agents for authoring, code agents for development)
- Are there agents loaded that aren't relevant to current phase? (context waste)
- Are there agents or skills missing that the current task needs?
- Are MCP servers appropriate? (e.g., Serena for code navigation, GitHub for PR work)

### Step 4: Recommend changes if needed
If the roster doesn't fit:
1. State which changes are needed and why
2. Make the changes (copy/remove agent/skill files, update .mcp.json)
3. Tell the user: **"Roster updated. Please restart to load the changes."**

---

## 3. Mid-Session Roster Adaptation

A project can be **code AND authoring** — the same project may need different tooling depending on phase. When the work context shifts (prose → code, code → documents, adding PR/issue work, architectural design), acknowledge it: "This task would benefit from [agent/skill]. It's not in the current roster. Shall I add it? A restart will be needed."

**Do NOT silently suffer with a mismatched roster.** If you need a tool you don't have, say so.

---

## 4. Project Type Detection — Context-Aware

**Project type is NOT just about file extensions.** A project's needs depend on:

| Factor | Example |
|--------|---------|
| **File structure** | Has `docs/`, `paper/` → authoring; has `src/`, `*.sln` → code |
| **Session context** | `session-context.md` describes the active task and phase |
| **Current phase** | Same project in "research" phase vs "implementation" phase needs different agents |
| **User's stated goal** | "Let's work on the paper today" overrides any heuristic |
| **Recent git history** | Last 5 commits touch only `.md` files → likely authoring session |

**Multi-modal projects** (e.g., a repo that is research + code + documentation) should have their roster adjusted per session, not fixed permanently.

---

## 5. Subagents — Source & Management

Subagents are sourced from community repositories. Primary upstream: `https://github.com/VoltAgent/awesome-claude-code-subagents`

```bash
# Clone source (once)
git clone https://github.com/VoltAgent/awesome-claude-code-subagents ~/.local/share/subagent-collections/voltagent-subagents

# Add / remove per project
cp ~/.local/share/subagent-collections/voltagent-subagents/<category>/<agent>.md <project>/.claude/agents/
rm <project>/.claude/agents/<agent>.md
```

### Parallelization — CRITICAL

**ALWAYS launch multiple agents in parallel when tasks are independent.** Use a single message with multiple Task tool calls.

### Model Selection

- `haiku` — quick lookups, simple searches
- `sonnet` — clear implementation tasks, routine code
- `opus` — judgment calls, architecture decisions, complex reasoning

---

## 6. Skills — Separate System, Complementary

Skills are NOT subagents. They are **procedural knowledge** loaded into the current agent's context.

| Aspect | Subagent | Skill |
|--------|----------|-------|
| Execution | Isolated context window | Loaded into YOUR context |
| Analogy | "Hiring a contractor" | "Reading the specialist's playbook" |
| Format | `.md` in `.claude/agents/` | `SKILL.md` in `.claude/skills/<name>/` |
| Context cost | Zero (runs separately) | Loaded on activation |

### Skill Sources & Discovery — Do It Rarely

Sources: `https://github.com/anthropics/skills` and `https://github.com/VoltAgent/awesome-agent-skills`. Clone locally for browsing, then copy to project.

**Discovery is triggered only at specific moments**, not at every session start:
- New project creation — browse catalog, select relevant skills
- User asks explicitly — browse for the requested domain
- Roster review reveals a gap — suggest browsing for the missing domain

### Skill Installation

```bash
# Clone sources (once)
git clone https://github.com/VoltAgent/awesome-agent-skills ~/.local/share/skill-collections/voltagent-skills
git clone https://github.com/anthropics/skills ~/.local/share/skill-collections/anthropic-skills

# Install per-project (preferred) or globally
cp -r ~/.local/share/skill-collections/<collection>/<skill-name> <project>/.claude/skills/
cp -r ~/.local/share/skill-collections/<collection>/<skill-name> ~/.claude/skills/
```

---

## 7. MCP Servers as Roster Items

MCP servers are defined in `~/.mcp.json` (global) or `<project>/.mcp.json` (per-project). Irrelevant servers consume startup time and add context waste. Prefer per-project `.mcp.json` with only what the current phase needs. Document which servers are relevant per session type in `session-context.md`. Restart required after changes.

Common servers: **GitHub** (repo/PR/issue management), **Serena** (semantic code navigation).

For troubleshooting and configuration details, see `~/.claude/reference/mcp-catalog.md`.
