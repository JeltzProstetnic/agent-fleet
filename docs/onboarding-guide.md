# Agent Fleet -- Getting Started

Your AI coding agent, configured once, running everywhere.

---

## Install (2 minutes)

```bash
git clone https://github.com/YOUR_USERNAME/agent-fleet ~/agent-fleet
cd ~/agent-fleet && bash setup.sh
```

That's it. The script detects your OS, installs dependencies, creates symlinks, and sets up hooks. No questions asked. When it finishes, you have a working agent.

**Windows users:** Run everything inside WSL. If you don't have WSL: open PowerShell as Admin, run `wsl --install`, restart, then use the Ubuntu app.

**Prerequisites:** git, Node.js 18+, and Claude Code. Python 3 is optional but recommended.

---

## Launch and talk

```bash
claude
```

Launch from the agent-fleet directory or any project directory. The agent handles everything from there.

### First launch

On first launch after setup, the agent detects a `.setup-pending` marker and starts a conversation about who you are and how you work. No forms. No config files to fill out. Just a conversation:

- What you do, what projects you work on
- How you like your agent to communicate (concise? verbose? sarcastic? formal?)
- Whether you want multiple personalities (e.g., a focused workhorse by default, a warmer tone when you're frustrated)
- Which external services to connect (GitHub, Gmail, Jira, etc.)

The agent writes everything to the right config files. You can change any of it later by just telling the agent.

### After that

Every session after the first is automatic. The agent pulls latest config, loads the right knowledge for the current project, restores session state, and checks for cross-project tasks. You just start working.

---

## Three commands to know

| Type this | What happens |
|-----------|-------------|
| `lsd` | Project dashboard -- shows all your projects, task counts, priorities |
| `cls` | Clean shutdown (saves state, commits, pushes), then ready for `/clear` |
| `end` | Clean shutdown, then exit |

Everything else -- creating projects, switching between them, deploying to other machines, managing backlogs, coordinating across projects -- you just tell the agent what you need.

---

## Common things you can say

| You say | The agent does |
|---------|---------------|
| "Set up this project" | Creates config, adds to registry, initializes session tracking |
| "Switch to project X" | Archives current state, opens a new tab in the other project |
| "Add GitHub integration" | Configures the MCP server, manages credentials |
| "Deploy this config to my other machine" | Commits, pushes; the other machine auto-pulls on next session |
| "Show me the backlog" | Reads and displays prioritized tasks for the current project |
| "Pass this task to the social project" | Drops it in the cross-project inbox |
| "What happened last session?" | Reads session history and summarizes |
| "Remember to always use bun instead of npm" | Adds a rule to the project or global config |

The agent knows about all your projects (via the registry), all your machines (via machine files), and all cross-project state (via the inbox and strategy files). You don't need to memorize file paths or command syntax.

---

## How it works (for the curious)

### Knowledge layers

The agent doesn't load everything at once. Knowledge is organized in 5 layers, each more specific:

| Layer | What | When loaded |
|-------|------|-------------|
| Global prompt | The dispatcher -- tells the agent what to load | Always |
| Foundation | Session protocol, your identity, personas | Always |
| Domains | Topic rules (TDD, infrastructure, publishing) | Only if the project declares them |
| References | Tool guides, troubleshooting | Only when needed |
| Project rules | Per-project CLAUDE.md and session state | Per project |

A coding project loads TDD rules. An infrastructure project loads server protocols. Nothing loads what it doesn't need.

### Session persistence

The agent maintains `session-context.md` in every project. It tracks what's being worked on, what's done, and how to resume. If a session crashes, the next session picks up from the checkpoint.

SessionEnd hooks auto-archive state even on unexpected exits. SessionStart hooks detect unclean shutdowns and warn accordingly.

### Cross-project coordination

Projects communicate through `cross-project/inbox.md`. When one project needs another to do something, it drops a task in the inbox. The target project picks it up at next startup.

Direct file writes between projects are forbidden -- this keeps projects decoupled and prevents silent data corruption.

### Multi-machine sync

Config syncs via git. Close on Machine A, open on Machine B -- same state, zero manual steps. Each machine has its own file in `global/machines/` tracking platform-specific details.

---

## Multi-machine setup

On a second machine:

```bash
git clone YOUR_REPO_URL ~/agent-fleet
cd ~/agent-fleet && bash setup.sh
```

Same two commands. The agent detects the new machine, creates a machine file, and everything syncs from there. You can also tell the agent "help me deploy to my other machine" and it will walk you through it.

| Syncs via git | Stays local |
|---------------|-------------|
| Rules, knowledge, session history | API tokens (`~/.mcp.json`) |
| Project configs, backlogs | OAuth credentials |
| Cross-project inbox | Machine-specific tool paths |

---

## What's included

### MCP servers (optional, configured during onboarding)

| Server | What it does |
|--------|-------------|
| GitHub | Repos, issues, PRs, code search |
| Google Workspace | Gmail, Docs, Calendar, Drive |
| Twitter/X | Post tweets |
| Jira | Issues, sprints, Confluence |
| Postgres | Database queries |
| Serena | Semantic code navigation |
| Playwright | Browser automation |
| Memory | Persistent knowledge graph |
| Context7 | Library documentation lookup |
| Diagram | Mermaid diagram generation |

### Credential vault

Portable encrypted token storage. One password, all your API keys, deployed to the right configs on any machine:

```bash
bash setup/secrets/vault-manage.sh encrypt    # Encrypt after editing
bash setup/secrets/vault-manage.sh deploy     # Decrypt + write to MCP configs
```

### Test suite

365 tests across 22 suites covering session rotation, config sync, dashboard, permissions, filtered push, mobile deploy, and more. The agent enforces TDD -- tell it to write code and it writes tests first.

### Skill collections

Third-party skill packs for Sentry debugging, security analysis, and more. Install with: `bash setup/scripts/install-skill-collections.sh`

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Agent doesn't see MCP servers | Restart Claude Code. Or tell the agent -- it knows how to diagnose this. |
| Permission prompts every session | Tell the agent to fix permissions -- it knows about settings.local.json cleanup. |
| Session state not persisting | Just tell the agent "my session state isn't persisting" -- it will diagnose. |
| Symlinks broken | `bash sync.sh setup` or tell the agent. |
| Something else | `bash sync.sh status` for a health check, or just describe the problem. |

The agent has built-in troubleshooting knowledge for all its infrastructure. Most issues can be resolved by describing the symptom.
