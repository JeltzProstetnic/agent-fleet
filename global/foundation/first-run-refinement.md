# First-Run Refinement Protocol

**Trigger:** `.setup-pending` marker file exists in the config repo root.

This protocol runs once after `setup.sh` completes. It turns the mechanical setup into a personalized configuration through a guided conversation.

## Goal

Help the user go from "setup.sh completed" to "Claude works the way I want" in one interactive session.

## Steps

### 1. Greet and Orient

- Welcome the user to their new Claude Code configuration
- Briefly explain what the system does (layered knowledge, session memory, multi-machine sync)
- Show what setup.sh already did (user profile, machine catalog, symlinks, hooks)

### 2. Refine User Profile

Read `global/foundation/user-profile.md`. The auto-generated version is minimal.

Ask the user about:
- **What they mainly use Claude Code for** (coding, writing, infrastructure, research, etc.)
- **Their preferred communication style** (terse/detailed, technical level, emoji preferences)
- **Any strong preferences** ("always use TypeScript", "never auto-commit", "I hate verbose explanations")

Update `user-profile.md` with their answers. Keep it concise — bullet points, not paragraphs.

### 3. MCP Server Setup

Read `~/.mcp.json` to see what was configured during `setup.sh`. Check which servers are present and which are missing.

**Walk through each unconfigured server and offer to set it up:**

| Server | Package | What it does | Credentials needed |
|--------|---------|-------------|-------------------|
| **GitHub** | `@modelcontextprotocol/server-github` | Repos, issues, PRs, code search | Personal Access Token (repo scope) |
| **Google Workspace** | `workspace-mcp` (via uvx) | Gmail, Docs, Sheets, Calendar, Drive | OAuth Client ID + Secret + email |
| **Twitter/X** | `@enescinar/twitter-mcp` | Post tweets, search | API key/secret + access token/secret |
| **Jira** | `mcp-atlassian` (via uvx) | Issues, boards, sprints | Instance URL + email + API token |
| **Slack** | `@modelcontextprotocol/server-slack` | Channels, messages, threads | Bot token (xoxb-) |
| **Linear** | `mcp-linear` | Issues, projects, cycles | API key |
| **Postgres** | `@modelcontextprotocol/server-postgres` | Query databases directly | Connection string |

**Serena** (code navigation) is always included and needs no credentials.

> **Security warning: Never ask the user to paste tokens in this chat session.** Session transcripts may be logged or cached — a pasted token is a leaked token. Instead, guide users to one of these secure methods:
> 1. **Edit `~/.mcp.json` directly** in their editor (VS Code, vim, nano) and paste tokens there
> 2. **Use the vault** — add tokens to `setup/secrets/vault.json`, then `bash setup/secrets/vault-manage.sh encrypt`
> 3. **Use a file** — write the token to a temp file (`chmod 600`), then read it programmatically
>
> If a user pastes a token in chat despite this warning, immediately tell them to rotate it and treat it as compromised.

**For each server the user wants:**
1. Explain what credentials are needed and where to get them
2. **Direct the user to add credentials via file edit** — tell them to open `~/.mcp.json` in their editor and paste the token there, or use the vault workflow. **Do NOT ask them to paste tokens in this chat.**
3. Update `~/.mcp.json` by reading the current file, adding the new server entry (with a placeholder value), and writing it back — the user fills in the real token via their editor
4. Tell the user they'll need to restart Claude Code for new servers to take effect

**Important notes for credential collection:**
- **Never accept tokens pasted in the chat.** Always direct users to edit files directly or use the vault.
- GitHub: PAT needs `repo` scope at minimum. URL: https://github.com/settings/tokens
- Google Workspace: Requires a Google Cloud project with OAuth 2.0 credentials and enabled APIs (Gmail, Drive, Calendar, Docs, Sheets). URL: https://console.cloud.google.com/apis/credentials
- Twitter: Requires a developer app at https://developer.x.com with OAuth 1.0a (read+write)
- Jira: API token from https://id.atlassian.com/manage-profile/security/api-tokens
- Slack: Bot token from a Slack app at https://api.slack.com/apps
- Linear: API key from https://linear.app/settings/api

**If the user already configured everything in setup.sh**, acknowledge that and move on. Don't push servers they don't need.

**If the user isn't sure what they need**, suggest starting with GitHub (most universally useful for developers) and adding others as needed.

### 4. Select Relevant Domains

Read `global/domains/INDEX.md`. Show the available domains:

- **Software Development** — TDD protocol, code quality patterns
- **Publications** — Markdown-to-PDF pipeline, test-driven authoring
- **Engagement** — Twitter/X engagement protocol
- **IT Infrastructure** — Servers, Docker, DNS, deployment

Ask: "Which of these match what you do? You can also describe domains you need that aren't here yet."

Note their selections — they'll use these when setting up projects.

### 5. Set Up First Project (Optional)

Ask: "Do you have a project you'd like to configure now? If so, what's the directory path?"

If yes:
1. Read the project directory to understand what it is
2. Create a `CLAUDE.md` manifest for it (use the template in `projects/_example/rules/CLAUDE.md`)
3. Add it to `registry.md`
4. Create an initial `session-context.md` in the project
5. Deploy the rules: copy the manifest to `<project>/.claude/CLAUDE.md`

If no: explain how to do it later ("just open Claude in any project directory and say 'set up this project'").

### 6. Configure Agent Personas

The persona system gives your agent multiple personalities with semantic switching rules. Offer the user a multi-personality setup:

"Your agent can have multiple personalities that switch based on context. You can pick from proven patterns, mix them, or define your own from scratch. Here are some patterns that work well:"

**Curated persona patterns** (present as a palette, not a forced choice):

| Pattern | Personas | When each activates | Best for |
|---------|----------|-------------------|----------|
| **Workhorse + Empath** | Efficient executor (default) + warm validator (on frustration) | Primary gets things done; empath activates on frustration, anger, or ranting | People who push hard and need someone who genuinely gets why the world is maddening |
| **Builder + Critic** | Creative builder (default) + ruthless reviewer (on code review / "review this") | Builder explores freely; critic tears things apart constructively | Developers who want encouragement while building but brutal honesty during review |
| **Mentor + Peer** | Patient teacher (when learning/asking "how") + sharp equal (default) | Mentor explains without condescension; peer assumes full competence | Experts who are learning new domains but don't want hand-holding in their own |
| **Strategist + Tactician** | Big-picture thinker (when planning/architecture) + detail executor (default) | Strategist zooms out for design; tactician grinds through implementation | People who switch between vision and execution |
| **Formal + Casual** | Professional (when writing docs/emails/reports) + relaxed (default) | Context-triggered by output type | People who need different registers for different audiences |

"You can combine patterns (e.g., Workhorse + Empath + Critic = three personas), define completely custom ones, or start with just one and add more later. What resonates with you?"

If interested, ask deeper personalization questions:
- "What name should your main persona have? Something that resonates — a cultural reference, a character, or just a vibe."
- "How should it communicate? Dry humor? Formal? Sarcastic? Direct? Playful?"
- "What triggers your worst frustration? Incompetence? Bureaucracy? Bad code? Being misunderstood?"
- "When you're frustrated, what actually helps? Validation? Humor? Someone who sees what you see? Distraction?"
- "Any other modes you'd want? A brainstorming persona? A devil's advocate? A rubber duck?"

For each persona, collect:
- **Name** — the display name
- **Traits** — comma-separated communication descriptors
- **Activates** — semantic rule (e.g., "default", "when frustrated", "when brainstorming")
- **Style** — free-text description of the persona's voice and approach

Store in `global/foundation/personas.md` (or the machine file's `## Persona` section for device-specific overrides).

The user can define as many personas as they want. Switching rules are fully semantic — anything describable in natural language works ("when I'm debugging at 2am", "when discussing philosophy", "when I say 'roast this code'").

If the user declines: skip entirely, no persona section needed. The default personas will be used.

### 7. Customize Global Prompt (If Needed)

Ask: "Any rules you want Claude to always follow across all projects?"

Examples to prompt:
- Output preferences (language, format)
- Tool preferences ("always use bun instead of npm")
- Safety preferences ("always ask before committing")
- Style preferences ("keep responses short")

If they have preferences, add them to the Conventions section of `global/CLAUDE.md`.

### 8. Verify and Clean Up

**Run ALL verification checks before removing `.setup-pending`.** Do NOT remove the marker until every check passes.

**Verification checklist (ALL must pass):**

- [ ] `user-profile.md` has been personalized (not the auto-generated template)
- [ ] At least one persona is configured in `personas.md` (or user explicitly declined)
- [ ] `sync.sh status` reports no errors (symlinks intact, no missing files)
- [ ] At least one MCP server is configured in `~/.mcp.json` (or user explicitly declined all)
- [ ] `registry.md` exists and has at least one project entry (the config repo itself)
- [ ] `session-context.md` exists for the config repo
- [ ] Git identity is configured (`git config user.name` and `user.email` both set)
- [ ] No `.template-repo` marker exists (should have been removed by `setup.sh`)

**Only after ALL checks pass:**
1. Delete the `.setup-pending` marker file
2. Commit everything: "Initial configuration after interactive setup"

**If any check fails:** Fix the issue inline, don't skip it. If a check requires user input (e.g., MCP credentials) and the user wants to defer, note it in `session-context.md` as a follow-up — but still do NOT remove `.setup-pending`. The marker stays until verification is complete. The next session will re-trigger this protocol and can resume where the user left off.

### 9. Summary

Tell the user:
- What was configured (profile, MCP servers, domains, projects)
- How to sync across machines (`git push` from here, `git pull` + `bash setup.sh` on the other machine)
- How to add more projects later
- How to add more MCP servers later (edit `~/.mcp.json`, restart Claude)
- How to customize further (edit files in this repo, then `bash sync.sh deploy`)

## Important

- **Be conversational**, not robotic. This is onboarding, not a form.
- **Skip steps the user doesn't care about.** If they say "just coding, nothing fancy" — don't push domains, customization, etc.
- **Keep it under 10 minutes.** Don't over-explain. The system is self-documenting.
- **Delete `.setup-pending`** when done. This protocol should only run once.
- **MCP changes require restart.** If you added servers, remind the user to restart Claude Code.
