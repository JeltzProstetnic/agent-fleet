# First-Run Refinement Protocol

**Trigger:** `.setup-pending` marker file exists in the config repo root.

This protocol runs once after `setup.sh` completes. It turns the mechanical setup into a personalized configuration through a guided conversation.

## Goal

Help the user go from "setup.sh completed" to "Claude works the way I want" in one interactive session.

## Steps

### 1. Greet — DON'T PANIC

Your very first output must be a warm, friendly greeting. Reference "DON'T PANIC" (Douglas Adams). Keep it to 2-3 sentences. No technical jargon, no bullet lists, no system details. Example tone: "DON'T PANIC. Everything's set up. I just need to know who I'm working with — what's your name?"

**One question at a time.** This is a conversation, not a form. Ask for the user's name first. Wait for their response. Then ask what they do. Wait. Then ask how they like to work. Each question builds on their previous answer. Match their vocabulary — if they say "dental research," don't reply with "infrastructure automation."

### 2. Refine User Profile (conversational, one question per turn)

Read `global/foundation/user-profile.md`. The auto-generated version is minimal.

Ask **only two things**, one at a time:
1. **Name** — "What's your name?"
2. **What they do / want help with** — "What do you do?" or "What would you like me to help with?"

**Do NOT ask about communication style or preferences.** Infer these from how the user writes. The persona pattern choice (step 2b) covers interaction style. Asking "how do you like to communicate?" is useless — people don't know how to answer it.

Update `user-profile.md` after these two answers. Adapt your vocabulary to match theirs — a scientist gets scientific vocabulary, a developer gets technical depth, a manager gets strategic framing.

### 2b. Configure Agent Personas

Present the persona patterns as a simple choice. The user picks a number, not a configuration form.

"I can work in different modes depending on the situation. Here are some proven combinations — pick the one that fits you best (you can change this anytime):"

| # | Pattern | What it means |
|---|---------|---------------|
| 1 | **Workhorse + Empath** | Gets things done efficiently. When you're frustrated, switches to genuine support and validation. |
| 2 | **Builder + Critic** | Explores ideas freely while building. Switches to ruthless honesty when reviewing code or designs. |
| 3 | **Mentor + Peer** | Explains things patiently when you're learning something new. Assumes full competence in your domain. |
| 4 | **Strategist + Tactician** | Zooms out for big-picture planning. Zooms in for detail work and implementation. |
| 5 | **Formal + Casual** | Professional tone for documents, emails, and reports. Relaxed and direct for everything else. |
| 6 | **Custom** | You describe what you want. |

"Just tell me the number, or describe what you'd like."

**After selection:** Briefly explain what the user chose in concrete terms ("When you're frustrated, I'll switch to [secondary persona] — more patient, more validating. When things are calm, I'm [primary persona] — efficient and direct. You can say 'switch to [name]' anytime, or I'll detect the shift automatically."). Then ask if they want to name the personas or keep the defaults.

**Key rule:** Always mention they can change personas anytime ("Just say 'change my persona' or 'I want a different style' and we'll reconfigure.")

For each persona, store in `global/foundation/personas.md`:
- **Name** — the display name
- **Traits** — comma-separated communication descriptors
- **Activates** — semantic rule (e.g., "default", "when frustrated")
- **Style** — free-text description

If the user declines: skip entirely, no persona section needed. The system works without it.

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

**For each server the user wants:**
1. Explain what credentials are needed and where to get them
2. Ask the user to paste the credentials
3. Update `~/.mcp.json` by reading the current file, adding the new server entry, and writing it back
4. Tell the user they'll need to restart Claude Code for new servers to take effect

**Important notes for credential collection:**
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
2. Create a `CLAUDE.md` manifest for it (use the template in `setup/projects/_example/rules/CLAUDE.md`)
3. Add it to `registry.md`
4. Create an initial `session-context.md` in the project
5. Deploy the rules: copy the manifest to `<project>/.claude/CLAUDE.md`

If no: explain how to do it later ("just open Claude in any project directory and say 'set up this project'").

### 6. Customize Global Prompt (If Needed)

Ask: "Any rules you want Claude to always follow across all projects?"

Examples to prompt:
- Output preferences (language, format)
- Tool preferences ("always use bun instead of npm")
- Safety preferences ("always ask before committing")
- Style preferences ("keep responses short")

If they have preferences, add them to the Conventions section of `global/CLAUDE.md`.

### 7. Verify and Clean Up

- Run `bash sync.sh status` to verify everything is linked correctly
- Delete the `.setup-pending` marker file
- Create an initial `session-context.md` for the config repo itself
- Commit everything: "Initial configuration after interactive setup"

### 8. Mobile Access (Optional)

Ask: "Do you want to access your agent fleet from a phone or tablet?"

If yes:
- Explain: mobile mode gives read-only access to projects + ability to post tasks from anywhere
- Run `bash sync.sh mobile-deploy` to generate `~/agent-fleet-mobile/`
- The mobile repo has its own lightweight CLAUDE.md — no startup checklist, instant-on
- Tasks posted to mobile outbox are auto-collected at next session end on any full machine
- Push the mobile repo to a private GitHub repo for phone access via the Claude Code mobile app

If no: skip. They can run `bash sync.sh mobile-deploy` anytime later.

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
