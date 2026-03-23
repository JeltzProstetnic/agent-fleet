# Design: Installer Dual-Mode UX

## Problem

The current installer (`install.sh`) has one mode: preview → confirm → execute. It detects non-interactive environments but doesn't offer distinct UX paths for different user types.

**New users** need explanation, context, and hand-holding. They don't know what "Phase 2: Claude Configuration" means or why they need a GitHub PAT.

**Experienced users** want `bash setup.sh --yes` and walk away.

## Proposal

Two explicit modes with automatic detection and manual override.

### Mode 1: Guided (default for TTY)

Interactive wizard that explains each step, asks for preferences, and configures incrementally.

```
$ bash setup.sh

Welcome to Agent Fleet — your persistent AI development assistant.

This setup takes about 5 minutes. I'll walk you through each step
and you can skip anything you're not ready for.

Step 1 of 5: System Dependencies
  Need to install: git, node 22, npm, uv
  This requires sudo (package manager).
  [Install now / Skip / Details]

Step 2 of 5: Claude Code
  Claude Code is the AI engine that powers everything.
  ✓ Already installed (v2.1.80)

Step 3 of 5: Integrations (all optional, add later anytime)
  Which services do you use?
  [x] GitHub        — manage repos, issues, PRs
  [ ] Gmail         — email triage, drafting
  [ ] Jira          — issue tracking, sprints
  [ ] Twitter/X     — post tweets
  [ ] PostgreSQL    — database queries

  Selected: GitHub
  → Enter your GitHub Personal Access Token (input is hidden):

Step 4 of 5: Configuration
  Deploying config files, hooks, and launchers...
  ✓ Symlinks created
  ✓ Session hooks installed
  ✓ afleet launcher deployed

Step 5 of 5: Ready!
  Run: afleet
  The agent will introduce itself and help you personalize everything.
```

#### Design principles for guided mode

1. **Progressive disclosure.** Don't front-load all options. Show one step at a time.
2. **Skip-friendly.** Every step has a skip option. MCP credentials can be added later via `afleet` conversation.
3. **Explain why.** Each step has a one-line explanation of what it does and why.
4. **Checkmarks for done.** Already-installed items show ✓ immediately — no redundant work.
5. **Recovery-friendly.** If the user Ctrl-C's mid-setup, re-running picks up where they left off (idempotent).
6. **No jargon.** "Integrations" not "MCP servers". "System Dependencies" not "Phase 1: Base System".

### Mode 2: Automated (default for non-TTY)

Non-interactive, CI-friendly. Uses defaults, reads credentials from environment or vault.

```
$ bash setup.sh --auto

[INFO] Detecting platform... Ubuntu 24.04 (WSL)
[INFO] Installing dependencies... done (12s)
[INFO] Claude Code... already installed (v2.1.80)
[INFO] MCP servers... configured from vault (3 servers)
[INFO] Deploying config... done
[INFO] afleet deployed to ~/.local/bin/

Setup complete. Run: afleet
```

#### Design principles for automated mode

1. **No prompts.** Uses defaults for everything. Credentials from env vars or vault.
2. **Exit codes matter.** 0 = success, 1 = fatal, 2 = partial (some optional steps skipped).
3. **Structured output.** Supports `--json` for machine-parseable results.
4. **Idempotent.** Safe to run repeatedly in CI or provisioning scripts.

### Mode Selection

| Condition | Mode |
|-----------|------|
| TTY attached, no flags | Guided |
| No TTY (pipe, CI, Claude Code) | Automated |
| `--auto` or `--yes` flag | Automated (even with TTY) |
| `--guided` or `--interactive` flag | Guided (even without TTY — will fail if no TTY) |

### Credential Flow

| Mode | Credential source | Behavior |
|------|-------------------|----------|
| Guided | Interactive prompt (masked input via `ask-passphrase.sh`) | Ask per-service, skip if declined |
| Automated | Env vars → vault → skip | `GITHUB_PAT=xxx bash setup.sh --auto` |

Environment variable names for automated mode:

```
GITHUB_PAT              GitHub Personal Access Token
GOOGLE_WORKSPACE_CREDS  Path to OAuth credentials JSON
JIRA_TOKEN              Jira API token
JIRA_URL                Jira instance URL
JIRA_EMAIL              Jira account email
TWITTER_API_KEY         Twitter API key
TWITTER_API_SECRET      Twitter API secret
TWITTER_ACCESS_TOKEN    Twitter access token
TWITTER_ACCESS_SECRET   Twitter access secret
```

### Implementation Plan

1. **Refactor install.sh** — extract step logic into functions, add mode routing
2. **New: `setup/lib-wizard.sh`** — guided mode UI helpers (step counter, checkbox selector, explanation panels)
3. **Update install-base.sh** — respect `$INSTALL_MODE` (guided|auto), adjust output verbosity
4. **Update configure-claude.sh** — respect `$INSTALL_MODE`, use env vars in auto mode
5. **Update preflight.sh** — in guided mode, explain each check; in auto mode, just pass/fail
6. **Test suite** — `test-install-dual-mode.sh` covering both paths + mode detection + credential flow

### What NOT to change

- The actual installation logic stays the same — same scripts, same phases
- `sync.sh` is untouched — it's a post-install tool
- First-run onboarding (`.setup-pending` → Claude conversation) stays — the installer handles mechanics, the agent handles personalization
- Rollback and upgrade paths are unchanged

### Open Questions

1. **Step numbering.** Should guided mode show total steps upfront ("Step 3 of 5") or use a progress bar? Total steps varies based on what's already installed.
2. **MCP server selection.** The checkbox UI needs a good TUI library or pure-bash implementation. Options: `dialog`/`whiptail` (requires install), `gum` (nice but another dep), or pure bash with arrow keys.
3. **Resumability.** Should we write a `.setup-progress` file tracking completed steps, so Ctrl-C + re-run skips completed work? Or is idempotency sufficient?

## Decision Needed

The core question: is this a **next release** priority or a **nice-to-have**? The current installer works. This improves first-impression UX significantly but doesn't add functionality.

Recommended: **P2** — implement after safe-run.sh propagation (CFG-247) and before any public launch push.
