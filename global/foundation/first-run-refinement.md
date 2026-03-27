# First-Run Refinement Protocol

**Trigger:** `.setup-pending` marker file exists in the config repo root.

This protocol runs once after `setup.sh` completes. It turns the mechanical setup into a personalized configuration through a guided conversation.

## Goal

Help the user go from "setup.sh completed" to "Claude works the way I want" in one interactive session.

## Steps

### 1. Greet — DON'T PANIC

The user already sees a DON'T PANIC ASCII banner as their first message. Your first output continues the tone — warm, brief, no technical jargon. Do NOT repeat "DON'T PANIC" — the banner already said it. Example tone: "Everything's set up. I just need to get to know you a bit. What's your name?"

**One question at a time.** This is a conversation, not a form. Ask for the user's name first. Wait for their response. Then ask what they do. Wait. Then ask how they like to work. Each question builds on their previous answer. Match their vocabulary — if they say "dental research," don't reply with "infrastructure automation."

### 2. Refine User Profile (conversational, one question per turn)

Read `global/foundation/user-profile.md`. The auto-generated version is minimal.

**Flow:**

1. **Name** — "What's your name?"
2. **After getting the name**, present ALL options in one structured message. Do NOT ask one thing at a time from here — show the full menu:

```
Nice to meet you, [name].

Next I recommend setting up a persona pattern and working hours for your own good:

[Persona patterns table — see step 2b below, labeled with letters]

Also we can set up one or several new projects:

[Project types table — see below, labeled with numbers]

Finally I would recommend you to let me:

X. Scan your machine and infrastructure to discover my environment (recommended*)
Y. Connect with services like email, calendar, social media and so on
Z. Both

* so I can help with your IT infrastructure like sorting files, fixing network issues, system problems etc.

Pick whatever you like — letters for persona, numbers for projects, X/Y/Z for setup. Or skip anything you're not interested in right now.
```

**Project types (labeled with numbers):**

| # | Type | What it's for |
|---|------|---------------|
| 1 | **Code** | Software development — any language, framework, or platform |
| 2 | **Writing** | Long-form authoring — books, fiction, creative writing |
| 3 | **Research** | Academic research, publications, data analysis |
| 4 | **Infrastructure** | Servers, networking, deployment, home lab |
| 5 | **Marketing** | Social media, engagement, visibility campaigns |
| 6 | **Business** | Process analysis, corporate tooling, decision support |
| 7 | **Data** | Data processing, catalogs, ETL, search/indexing |
| 8 | **Media** | Media management — organization, dedup, sync |
| 9 | **Tooling** | Integration tooling — connecting systems, automation |
| 10 | **Custom** | Describe what you need — I'll figure it out |

**Do NOT ask vague questions.** Present concrete choices. The user picks letters/numbers/X/Y/Z. Process whatever they choose, skip what they don't mention.

Update `user-profile.md` with name and whatever you learn. Adapt vocabulary to match theirs.

### 2c. Infrastructure Scan (when user picks X or Z)

Run a quick scan and report findings conversationally:
- **Installed tools:** `node`, `python`, `git`, `docker`, `npm`, `cargo`, etc.
- **Disks/mounts:** `df -h` for available storage
- **Network:** hostname, SSH keys in `~/.ssh/`, any running services
- **Data sources:** databases, CSV/JSON files, interesting directories
- **Existing projects:** git repos under `~/`

Present findings as: "Here's what I found on your machine: [summary]. Based on this, you might want projects for [suggestions]."

### 2d. Service Connection (when user picks Y or Z)

Offer to connect external services via MCP:
- **Email:** Gmail, Outlook
- **Calendar:** Google Calendar
- **Social:** Twitter/X, LinkedIn
- **Code:** GitHub, GitLab
- **Work tools:** Jira, Confluence, Slack

Each connection requires API keys or OAuth. Walk the user through setup one service at a time.

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

### 3. Execute Selections

Process whatever the user chose from the menu above. For each:

**Persona:** Write to `global/foundation/personas.md`. Ask for persona names if they want custom ones, otherwise use defaults (e.g., "Gears" + "Soft" for Workhorse + Empath). Briefly explain what they chose and mention they can change anytime.

**Project:** Create directory, initialize with `project-setup.md` template, add to `registry.md`. Walk through any project-specific setup.

**Scan (X/Z):** Run infrastructure scan (step 2c above). Present findings, suggest projects based on what you find.

**Connect (Y/Z):** For each service, explain what credentials are needed and where to get them. Services available:
- **GitHub:** PAT with `repo` scope → https://github.com/settings/tokens
- **Gmail/Calendar/Drive:** Google Cloud OAuth → https://console.cloud.google.com/apis/credentials
- **Twitter/X:** Developer app → https://developer.x.com
- **Jira:** API token → https://id.atlassian.com/manage-profile/security/api-tokens
- **LinkedIn, Slack, Postgres:** credentials as needed

Update `~/.mcp.json` for each. Remind user to restart CC for new servers.

### 4. Features Showcase

After processing all selections, present a final overview of available capabilities. This is informational — no action needed from the user.

"You're all set. Here's what's available to you now — and what you can unlock later:

**Built-in capabilities:**
- **Backlog management** — every project gets a `backlog.md` with prioritized tasks, tracked automatically. No external tool needed. (If you use Jira, I can work with that too — it just costs more tokens per operation.)
- **Session memory** — I remember what we were doing across sessions, machines, and crashes. Say `cls` to shut down cleanly.
- **Document management** — I can catalog, organize, and track documents across your machines. PDFs, reports, research papers — filed and findable.
- **File management** — sorting, deduplication, bulk operations, cross-disk organization. Tell me about your file chaos and I'll help.
- **Cross-project coordination** — tasks flow between projects automatically via an inbox system.

**Available skills (activate by describing the problem):**
- **Simulation & optimization** — discrete-event simulation for queueing, scheduling, resource allocation, throughput optimization. Say 'simulate' or describe a system with queues and servers.
- **Self-audit (`lrn`)** — when something goes wrong, I analyze root causes and create prevention rules. Say `lrn` to trigger.

**Multi-machine & server (available now, set up on demand):**
- **Multi-machine sync** — same setup on office PC, laptop, home server, Steam Deck. Git-based, automatic.
- **Server deployment** — run agent fleet on a VPS for remote/mobile access via web terminal
- **Mobile access** — lightweight repo for managing projects from your phone

**Upcoming:**
- **Muse** — AI-powered creative studio for image generation, art direction, and visual content creation
- **Full GUI** — desktop dashboard with visual project management, progress indicators, and persona face
- Browser automation — web scraping, form filling, testing

Type `lsd` for a project dashboard anytime. Everything is documented — just ask."

### 5. Verify and Clean Up

- Run `bash sync.sh status` to verify everything is linked
- Delete `.setup-pending` marker file
- Create initial `session-context.md`
- Commit: "Initial configuration after interactive setup"

## Important

- **Be conversational**, not robotic. This is onboarding, not a form.
- **Skip steps the user doesn't care about.** Process only what they chose.
- **Keep it under 10 minutes.** Don't over-explain.
- **Delete `.setup-pending`** when done. This protocol runs once.
- **MCP changes require restart.** Remind the user if servers were added.
