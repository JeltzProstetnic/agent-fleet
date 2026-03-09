# Getting Started with Agent Fleet

A step-by-step walkthrough for setting up and using Agent Fleet. This guide assumes you have read the [README](../README.md) and want the practical how-to.

---

## 1. What Agent Fleet Does

Claude Code is stateless. Every session starts from zero. It has no memory of what you did yesterday, no awareness of your other projects, and no way to carry context between machines. Built-in auto-memory helps within a single project, but breaks down when you work across multiple codebases or computers.

Agent Fleet solves this with a single git-synced configuration repo that gives Claude:

- **Session persistence** -- structured state files that survive crashes, `/clear`, and context resets, with explicit recovery instructions for the next session
- **Cross-project coordination** -- projects pass tasks to each other through a shared inbox, so finishing work in one project can trigger follow-up in another
- **Multi-machine sync** -- close your laptop, open your desktop, pick up where you left off. Config travels via git push/pull
- **Conditional knowledge loading** -- domain rules (TDD, infrastructure, publishing) load only when the project needs them, keeping the context window lean

The repo is the source of truth. Claude reads it at startup, writes to it during work, and commits changes at shutdown.

---

## 2. Prerequisites

**Required:**

| Tool | Minimum version | Install |
|------|----------------|---------|
| Git | Any recent | `sudo apt install git` (Ubuntu/WSL) or `brew install git` (macOS) |
| Node.js | 18+ | `sudo apt install nodejs npm` or `brew install node` |
| Claude Code | Latest | [docs.anthropic.com/en/docs/claude-code](https://docs.anthropic.com/en/docs/claude-code/getting-started) |

**Optional but recommended:**

| Tool | Why |
|------|-----|
| Python 3 | Enhances setup and sync scripts. Pre-installed on most systems. |
| Pandoc + weasyprint | PDF generation from markdown (used by output rules). |

**Windows users:** Claude Code runs inside WSL, not natively. If you have not set up WSL, open PowerShell as Administrator, run `wsl --install`, restart, then open the Ubuntu app. Everything below happens inside that Linux terminal. Always work in the Linux filesystem (`~/`), never in `/mnt/c/` -- Windows paths are 10-15x slower.

---

## 3. Installation

### Step 1: Fork and clone

Fork the repo on GitHub, then clone it:

```bash
git clone https://github.com/YOUR_USERNAME/agent-fleet ~/agent-fleet
```

### Step 2: Run setup

```bash
cd ~/agent-fleet && bash setup.sh
```

The script is interactive. It will:

1. **Detect your platform** -- Ubuntu, Fedora, Arch, macOS, SteamOS, or WSL. Package manager and paths adjust automatically.
2. **Install system dependencies** -- pandoc, weasyprint, and other tools if missing. Asks before installing anything.
3. **Create your user profile** -- prompts for your name, role, and communication preferences. Stored in `global/foundation/user-profile.md`.
4. **Set up symlinks** -- links `global/` files into `~/.claude/` so Claude reads them automatically.
5. **Install session hooks** -- copies startup and shutdown scripts to `~/.claude/hooks/`. These handle auto-sync, session rotation, and crash recovery.
6. **Configure MCP servers** (optional) -- asks about GitHub, Gmail, and other integrations. Skip any you do not need; add them later.

### Step 3: Verify

```bash
bash sync.sh status
```

This runs a health check. You should see symlinks confirmed and no errors. If anything is broken, it tells you what to fix.

### Step 4: Set up credentials (optional)

If you configured MCP servers that need tokens:

```bash
cp setup/secrets/vault.json.example setup/secrets/vault.json
# Edit vault.json with your tokens
bash setup/secrets/vault-manage.sh encrypt
```

The plaintext `vault.json` is gitignored. Only the encrypted `.enc` file is committed, so your tokens never appear in git history.

### Step 5: Start using it

Open Claude Code in any project directory. It automatically picks up your Agent Fleet configuration through the symlinked `~/.claude/CLAUDE.md`.

---

## 4. Key Concepts

### Registry (`registry.md`)

The master list of all your projects. Each row has a name, path, priority (P1-P5), type, and optional parent project. Claude reads this to know what exists, where it lives, and how important it is.

Add a row whenever you create a new project. The `lsd` dashboard reads from here.

### Session Context (`session-context.md`)

A per-project state file that tracks what Claude is working on, what has been completed, and how to resume if the session ends unexpectedly. Created automatically in each project directory.

Claude updates this file continuously during work. At startup, it reads the file to restore context. At shutdown, it archives the file to session history before resetting it for the next session.

### Cross-Project Inbox (`cross-project/inbox.md`)

The only mechanism for projects to communicate. When work in one project requires follow-up in another, you (or Claude) add a task entry:

```
- [ ] **target-project**: Description of what needs to happen
```

At session start, Claude checks the inbox for tasks targeting the current project, picks them up, and deletes the entry. Tasks are never broadcast -- each entry targets exactly one project.

### Backlogs (`backlog.md`)

Per-project task lists with standardized format and priority tags:

```
- [ ] [P1] **Critical task**: Must do immediately
- [ ] [P2] **Active task**: Do this week
- [ ] [P3] **Ongoing task**: Do when time allows
```

Priorities P1 through P5 mirror project priorities in the registry. Completed tasks move to a `## Done` section grouped by date. Claude reads backlogs on demand, not at startup.

### Knowledge Layers

Configuration loads in five layers, each more specific than the last:

| Layer | Location | Loaded when |
|-------|----------|-------------|
| **1. Global prompt** | `global/CLAUDE.md` | Always -- the dispatcher that tells Claude what else to load |
| **2. Foundation** | `global/foundation/` | Always -- session rules, your identity, core protocols |
| **3. Domains** | `global/domains/` | Only if the project declares a need (e.g., TDD rules for code projects) |
| **4. References** | `global/reference/` | Only when triggered (e.g., MCP troubleshooting when a tool fails) |
| **5. Project rules** | `<project>/.claude/CLAUDE.md` | Per project -- declares which domains to load, project-specific instructions |

This layering keeps context usage low. A writing project never loads infrastructure rules. A CLI tool never loads publishing protocols.

---

## 5. Daily Workflow

A typical session looks like this:

**1. Start.** Open your terminal, navigate to a project, and launch Claude Code.

```bash
cd ~/my-project
claude
```

**2. Auto-load.** Claude automatically pulls the latest config from git, reads your session context, checks the cross-project inbox for pending tasks, and loads the appropriate knowledge layers. This takes a few seconds.

**3. Work.** Use Claude normally. Session state saves continuously. Domain rules enforce quality automatically (e.g., TDD requires tests before implementation). You do not need to think about the infrastructure.

**4. End.** When you are done, type one of the shutdown commands:

```
cls     Save state, archive session, commit, push -- then /clear
end     Save state, archive session, commit, push -- then exit
```

Both run the full shutdown protocol. The difference: `cls` prepares for a new session in the same terminal, `end` signals you are leaving.

**5. Switch projects.** Type `lsd` to see the project dashboard:

```
lsd     Show all projects with status, tasks, and sizes
```

The dashboard displays your projects grouped by priority tier, with task counts and the option to switch by number. Type `switch 3` to open project #3 in a new terminal tab.

### The three commands to remember

| Command | What it does |
|---------|-------------|
| `cls` | Full shutdown, then clear for new session |
| `end` | Full shutdown, then exit |
| `lsd` | Project dashboard -- browse, switch, create |

These are the only commands you need to memorize. Everything else is conversational -- just tell Claude what you want.

---

## 6. Adding a New Project

### Option A: Let Claude do it

Navigate to your project directory and start Claude Code:

```bash
cd ~/my-new-project
claude
```

Tell Claude: "Set up this project." It will:

1. Create `.claude/CLAUDE.md` with a project manifest
2. Add the project to `registry.md`
3. Initialize `session-context.md`
4. Ask which domain protocols to enable

### Option B: Manual setup

Create the project config file:

```bash
mkdir -p ~/my-new-project/.claude
```

Copy the example from `setup/projects/_example/rules/CLAUDE.md` into `~/my-new-project/.claude/CLAUDE.md` and edit it. At minimum, declare a knowledge loading table that lists which domains this project needs.

Add a row to `registry.md` with the project name, path, priority, and type. Session tracking begins the next time you open Claude Code in that directory.

---

## 7. Adding a New Machine

### Step 1: Clone and set up

On the new machine:

```bash
git clone YOUR_REPO_URL ~/agent-fleet
cd ~/agent-fleet && bash setup.sh
```

The setup script detects the platform automatically and creates a machine-specific configuration file in `global/machines/`.

### Step 2: Sync

Push from the new machine. Pull on your other machines. Config now flows both ways via git.

```bash
# On the new machine, after setup:
git add -A && git commit -m "Add new machine config" && git push

# On other machines, next session start:
# (auto-pull happens via startup hooks)
```

### What stays local vs. what syncs

| Syncs via git | Stays on each machine |
|---------------|----------------------|
| Global rules and foundation files | `~/.mcp.json` (tokens differ per machine) |
| Domain protocols | OAuth tokens and credentials |
| Session history and project configs | Machine-specific tool paths |
| Cross-project inbox | `~/CLAUDE.local.md` (points to local machine file) |

No machine is special. Any machine with the repo cloned and `setup.sh` run is a full participant.

---

## 8. Quick Reference Card

| Task | How |
|------|-----|
| End session cleanly | Type `cls` (clear after) or `end` (exit after) |
| See all projects | Type `lsd` |
| Switch to another project | `lsd` then `switch N` |
| Add a new project | Navigate to project dir, tell Claude "set up this project" |
| Sync config to live locations | `bash sync.sh deploy` |
| Pull config changes back | `bash sync.sh collect` |
| Check system health | `bash sync.sh status` |
| Pass a task to another project | Add `- [ ] **project-name**: task` to `cross-project/inbox.md` |
| Add a new machine | Clone repo, run `bash setup.sh` |
| Update MCP tokens | Edit `setup/secrets/vault.json`, then `bash setup/secrets/vault-manage.sh encrypt` |
| Deploy tokens to MCP configs | `bash setup/secrets/vault-manage.sh deploy` |
| Add a domain protocol | Copy `global/domains/_template/`, edit, reference from project manifest |
| Install skill collections | `bash setup/scripts/install-skill-collections.sh` |

---

## Next Steps

- **Customize your profile** -- edit `global/foundation/user-profile.md` with your name, role, and communication preferences
- **Configure MCP servers** -- add tokens to the vault or edit `~/.mcp.json` directly
- **Add your projects** -- use `lsd` and "set up this project" to register existing codebases
- **Read the README** -- the [README](../README.md) covers architecture, security, and troubleshooting in depth
- **Explore domains** -- check `global/domains/` for available rule sets and create your own
