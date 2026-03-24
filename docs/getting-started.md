# Getting Started with Agent Fleet

Claude Code is stateless — every session starts from zero. Agent Fleet fixes that. It's a git-synced configuration layer that gives Claude session persistence, cross-project coordination, multi-machine sync, and conditional knowledge loading. The repo is the source of truth: Claude reads it at startup, writes to it during work, and commits at shutdown.

For architecture details, see the [README](../README.md). This guide gets you from zero to a working setup.

---

## 1. Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Git | Any recent | `sudo apt install git` / `brew install git` |
| Node.js | 18+ | `sudo apt install nodejs npm` / `brew install node` |
| Claude Code | Latest | [docs.anthropic.com](https://docs.anthropic.com/en/docs/claude-code/getting-started) |

Claude Code requires either a **Max subscription** or **API access**.

**Optional:**

| Tool | Why |
|------|-----|
| Python 3 | Enhances setup scripts. Pre-installed on most systems. |
| Pandoc + weasyprint | PDF generation from markdown. |

> **Windows users:** Claude Code runs inside WSL. If you haven't set it up: open PowerShell as Administrator, run `wsl --install`, restart, then open the Ubuntu app. Everything below happens in that Linux terminal. Work in `~/`, never in `/mnt/c/` — Windows paths are 10-15x slower.

---

## 2. Installation

### Step 1: Clone

```bash
git clone https://github.com/JeltzProstetnic/agent-fleet ~/agent-fleet
```

> **Want a private copy?** Click "Use this template" on GitHub to create your own repo, then clone that URL instead. Don't fork — forks can't be private and your config will contain personal data. Setup auto-detects the template origin and reconfigures remotes.

### Step 2: Run setup

```bash
bash ~/agent-fleet/setup.sh
```

The installer is interactive and runs in three phases:

1. **System dependencies** — installs tools if missing (asks first, requires sudo)
2. **Claude configuration** — sets up MCP servers, launcher script, git config
3. **Deploy to live** — symlinks config into `~/.claude/`, installs hooks, creates the `afleet` launcher

Preview without changing anything: `bash ~/agent-fleet/setup.sh --dry-run`

### Step 3: Verify

```bash
bash ~/agent-fleet/sync.sh status
```

You should see symlinks confirmed and no errors. If something is broken, it tells you what to fix.

### Step 4: Credentials (optional)

If you configured MCP servers that need tokens:

```bash
cp ~/agent-fleet/secrets/vault.json.example ~/agent-fleet/secrets/vault.json
# Edit vault.json with your tokens (never commit this file — it's gitignored)
bash ~/agent-fleet/secrets/vault-manage.sh encrypt
bash ~/agent-fleet/secrets/vault-manage.sh deploy
```

Only the encrypted `.enc` file is committed. Your tokens never appear in git history.

---

## 3. First Launch

### How to start

```bash
afleet
```

Use `afleet`, not `claude` directly. `afleet` syncs repos, detects your project, and ensures everything is loaded before handing off to Claude Code.

### What happens the first time

Setup creates a `.setup-pending` marker. When Claude detects it, it triggers a one-time **first-run refinement** — a guided conversation that turns the mechanical setup into a personalized configuration.

**The agent will walk you through:**

1. **Your profile** — name, role, what you use Claude for, communication style. Stored in `user-profile.md`.
2. **MCP servers** — which services to connect (GitHub, Gmail, Jira, etc.). The agent guides you through credentials securely — it will never ask you to paste tokens in the chat.
3. **Domains** — which rule sets match your work (software development, infrastructure, publishing).
4. **First project** — optionally register an existing codebase.
5. **Personas** — customize the agent's personality. Pick from proven patterns (Workhorse+Empath, Builder+Critic, Mentor+Peer) or define your own. Or skip for defaults.
6. **Global rules** — any "always do X" preferences across all projects.

After onboarding, the agent verifies everything, removes `.setup-pending`, and commits. The next session starts automatically — no more onboarding.

> **Security:** The agent will never ask you to paste tokens in the chat. It directs you to edit files or use the vault. If you accidentally paste a token, rotate it immediately.

---

## 4. Daily Workflow

**Start:**

```bash
afleet                  # auto-detect project from current dir
afleet my-project       # launch specific project
afleet --pick           # interactive project picker
```

On startup, Claude automatically pulls config, restores session context, checks the inbox for pending tasks, and loads knowledge layers. Takes a few seconds.

**Work normally.** The infrastructure is invisible. Session state saves continuously. Domain rules enforce quality automatically (TDD, session checkpoints, etc.).

**End:** Type one of these as your entire message:

| Command | What it does |
|---------|-------------|
| `cls` | Full shutdown (save, archive, commit, push), then `/clear` for new session |
| `end` | Full shutdown, then exit |
| `lsd` | Project dashboard — browse all projects, switch by number |

If a session crashes, the shutdown hook saves state automatically. The next session resumes where you left off.

---

## 5. Project Management

### Let Claude do it

Navigate to a project directory and launch:

```bash
afleet
```

Tell Claude: *"Set up this project."* It will create the config manifest, add it to the registry, initialize session tracking, and ask which domain rules to enable.

### Manual setup

```bash
mkdir -p ~/my-project/.claude
cp ~/agent-fleet/setup/projects/_example/rules/CLAUDE.md ~/my-project/.claude/CLAUDE.md
```

Edit the manifest. At minimum, declare a Knowledge Loading table listing which domains the project needs. Add a row to `registry.md` with the project name, path, priority (P1-P5), and type.

### Cross-project coordination

Projects communicate through a shared inbox (`cross-project/inbox.md`):

```markdown
- [ ] **target-project**: Description of what needs to happen
```

At session start, Claude checks for tasks targeting the current project, picks them up, and deletes the entry after completion.

---

## 6. Multi-Machine Setup

Same two commands on the new machine:

```bash
git clone YOUR_REPO_URL ~/agent-fleet
bash ~/agent-fleet/setup.sh
```

Setup detects the platform and creates a machine-specific config file.

### What syncs vs. what stays local

| Syncs via git | Stays on each machine |
|---------------|----------------------|
| Rules, foundation, domains | `~/.mcp.json` (tokens differ per machine) |
| Session history, project configs | OAuth tokens and credentials |
| Cross-project inbox | Machine-specific tool paths |
| Backlogs and knowledge files | `~/CLAUDE.local.md` (machine identity) |

Session hooks handle sync automatically — no manual push/pull in normal operation. Close your laptop, open your desktop, pick up where you left off.

---

## 7. Persona System

Personas give your agent distinct personalities with automatic context-based switching.

**Defaults:** Assistant (efficient, default) and Supporter (warm, activates on frustration).

**Customize:** Edit `global/foundation/personas.md` or tell the agent during first-run refinement. Each persona has:

- **Name** — display name
- **Traits** — communication style descriptors
- **Activates** — semantic trigger (e.g., "default", "when frustrated", "when reviewing code")
- **Style** — free-text voice description

Switching rules are fully semantic — anything describable in natural language works. Day/Night mode applies automatically on top: after 17:00 on weekdays, responses get shorter and the agent prefers tracking over executing.

---

## 8. Updating

```bash
bash ~/agent-fleet/setup/scripts/upgrade.sh
```

This creates a rollback checkpoint (git tag), pulls the latest from upstream, and deploys to live locations.

**Your customizations are safe.** Personas, machine files, hostname mappings, secrets — all live in `.local` files that upgrades never touch.

```bash
bash ~/agent-fleet/setup/scripts/upgrade.sh --dry-run     # preview
bash ~/agent-fleet/setup/scripts/upgrade.sh --rollback     # revert
bash ~/agent-fleet/setup/scripts/upgrade.sh --list-tags    # see checkpoints
```

---

## 9. Quick Reference

| Task | How |
|------|-----|
| End session cleanly | `cls` (stay) or `end` (exit) |
| See all projects | `lsd` |
| Add a project | Navigate to dir, tell Claude "set up this project" |
| Self-audit | `lrn` |
| Delegate to background | `sub <task description>` |
| AFK mode (mobile) | `afk` |
| Sync config manually | `bash sync.sh deploy` (push) / `bash sync.sh collect` (pull) |
| Health check | `bash sync.sh status` |
| Pass task to another project | Add to `cross-project/inbox.md` |
| Update MCP tokens | Edit vault.json, `vault-manage.sh encrypt`, `vault-manage.sh deploy` |

---

## 10. Troubleshooting

| Problem | Fix |
|---------|-----|
| MCP servers not loading | Restart Claude Code — MCP loads at startup only |
| Permission prompts every session | Tell the agent — it knows about `settings.local.json` |
| Symlinks broken after git pull | `bash sync.sh setup` |
| Session state not persisting | Describe the symptom to the agent — it will diagnose |
| General health check | `bash sync.sh status` |

> **Warning: Never run `/init` in a project managed by Agent Fleet.** The `/init` command generates a fresh `CLAUDE.md`, overwriting the one Agent Fleet maintains. If this happens, restore it with `git checkout -- CLAUDE.md`. Agent Fleet's `CLAUDE.md` files contain an `<!-- agent-fleet-managed -->` marker comment — the presence of this marker is your signal that the file is managed and should not be regenerated.

For architecture details, security model, and advanced troubleshooting, see the [README](../README.md).

---

## Next Steps

- **Customize your profile** — edit `global/foundation/user-profile.md`
- **Add your projects** — use `afleet` and "set up this project"
- **Explore domains** — check `global/domains/` for available rule sets
- **Read the README** — covers architecture, security, and the full feature set
