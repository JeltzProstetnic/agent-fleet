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

## VoltAgent Context Window Threshold

Before selecting agents, determine whether VoltAgent bundles should be enabled at all:

| Context Window | Default | Rationale |
|----------------|---------|-----------|
| **<= 200k** | VoltAgent **OFF** | Each bundle costs ~10k tokens. On small windows, bundles consume a significant fraction of available context. User must opt in explicitly. |
| **> 200k** | VoltAgent **ON** | Token cost is negligible relative to window size. Agent picks best-fit agents during project creation. |

**How to detect:** The model's context window is part of its declared parameters. As of 2026, claude-sonnet-4-x = 200k, claude-opus-4-x = 200k, claude-haiku-3-5 = 200k. When in doubt, treat as <= 200k and offer opt-in.

---

## New Project Setup Steps

1. **Understand the project and determine type** — read any existing files, ask the user about goals, tech stack, phases
   - Determine the project type from `reference/project-types.md` (canonical types: code, writing, research, config, infra, marketing, business, data, media, tooling)
   - If no exact type match, use the closest canonical type or combine with `+` (e.g., `research + writing`)
   - **Consult sibling projects** — structured comparison, not guessing:
     1. **Find siblings:** Read `registry.md` Type column. Match projects with the same or overlapping types.
     2. **Read each sibling's CLAUDE.md.** Extract: Knowledge Loading table, build commands, git rules, delivery rules, communication rules, directory structure, active roster.
     3. **Compare against the type template.** Identify project-specific additions vs type-generic patterns.
     4. **Weight by maturity.** If a sibling has 50+ commits, its patterns are battle-tested.
     5. **Apply relevant patterns, skip project-specific ones.** Example: a writing project's publication workflow applies to other writing projects; its specific publisher's requirements don't.
     6. **Document what you adopted** in a comment in the new project's CLAUDE.md.
2. **Select subagents** — this is a judgment task:
   - Check the context window threshold (above) to decide if VoltAgent is appropriate
   - If VoltAgent is ON: browse plugin marketplace categories to understand what's available
   - Reason about the project domain, tech stack, and current phase, then pick 4-8 agents that best match
   - `setup-project-roster.sh` has a type→bundle mapping as a reference starting point, but use your own judgment
   - If VoltAgent is OFF: skip bundle selection; note in CLAUDE.md that user can opt in
3. **Run skill discovery** — browse skill catalog, select relevant skills for the project type
4. **Configure MCP servers** — determine which servers are needed (code → Serena; GitHub repo → GitHub MCP; etc.)
5. **Set up roster** — create `.claude/agents/`, `.claude/skills/`, copy selected files
6. **Create session-context.md** — initial project state. Also create `tmp/` (gitignored, throwaway) and `drafts/` (tracked, content awaiting user action) directories
7. **Add project to registry**: update `~/agent-fleet/registry.md`
8. **Tell the user**: "Roster set up with N agents and M skills. Please restart to load them."

---

## Suggested Startup Patterns

During project setup, suggest domain-appropriate startup patterns for the project's `CLAUDE.md`. These are optional but recommended for specific project types.

### Platform Scan (social / marketing / communications projects)

**Suggest when:** project type is social media, marketing, communications, outreach, or PR.

Add a "Session Startup — Platform Scan" section to the project's `CLAUDE.md` that runs after the standard loading protocol. The scan should:

1. **Scan available platforms** for news, engagement targets, and opportunities:
   - Twitter/X (search + mentions), LinkedIn (posts, messages), Gmail (via Google Workspace MCP), web (news, papers, blog posts)
   - Scope platforms to the project's domain — not every project needs all platforms

2. **Classify and route items:**
   - Items actionable within this project → prepare in-session
   - Items belonging to another project → post to cross-project inbox
   - Ambiguous items → ask user

3. **Prepare ready-to-use deliverables:**
   - Copy-pastable content (tweet drafts, post drafts, reply text) → write to `drafts/` files (persist across sessions)
   - Click lists (URLs for engagement actions) → write to `tmp/` files (throwaway)
   - One best option per target (don't present multiple alternatives)

4. **Cross-reference** targets against shared contact/engagement tracking files before drafting

---

## Operational Readiness (for projects with deployment)

When creating a project that deploys to a remote host, verify before declaring setup complete:

- [ ] Deploy script works from the creating machine
- [ ] All required credentials (SSH keys, FTP, API tokens) have vault entries with `deploy_to` targets
- [ ] SSH keys/config deployed to all machines via `vault-manage.sh deploy`
- [ ] Deploy script uses correct ports and connection parameters
- [ ] Project `CLAUDE.md` Knowledge Loading includes vault ops trigger if credentials are needed
- [ ] Cross-machine deploy tested or documented as pending

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

## Document Integration (if project produces persistent artifacts)

Projects that generate or manage reference documents (research papers, guidelines,
correspondence, certificates, regulatory docs) should catalog them in the central DMS.

- **DMS location:** `~/agent-fleet/dms/` — catalog + intake protocol
- **Cross-project rule:** Only the config project writes to `dms/`. Other projects post
  intake requests to `~/agent-fleet/cross-project/inbox.md`:
  `- [ ] **config-project**: DMS intake — <doc description>, source: <project>:<path>, category: <prefix>`
- **Project-origin tagging:** Use Tags column with `from:<project>` (e.g., `from:myproject`)
- **Per-project catalogs:** If a project generates many artifacts of the same category,
  request a dedicated catalog file via inbox
```

## Cross-Project References (if applicable)

- Strategy files: `~/agent-fleet/cross-project/<name>-strategy.md`
