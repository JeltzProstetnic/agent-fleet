# First-Run Refinement Protocol

**Trigger:** `.setup-pending` marker file exists in the config repo root.

This protocol runs once after `setup.sh` completes. It turns the mechanical setup into a personalized configuration through a guided conversation.

## Goal

Help the user go from "setup.sh completed" to "Claude works the way I want" in one interactive session.

## Steps

### 1. Greet — DON'T PANIC

The user already sees a DON'T PANIC ASCII banner as their first message. Your first output continues the tone — warm, brief, no technical jargon — and is the Coordinator introduction of step 1b. Do NOT repeat "DON'T PANIC" — the banner already said it. Example tone for the name question after step 1b: "Everything's set up. I just need to get to know you a bit. What's your name?"

**One question at a time.** This is a conversation, not a form. Ask for the user's name first, right after step 1b. Wait for their response. Then ask what they do. Wait. Then ask how they like to work. Each question builds on their previous answer. Match their vocabulary — if they say "dental research," don't reply with "infrastructure automation."

### 1b. Meet your Coordinator

Comes right after the banner, before any other step. This project — the config project — introduces itself as the **Coordinator Project**, and its persona name is **Coordinator**. Explain the role briefly and concretely, in the user's words:

"I'm your Coordinator, and this is the Coordinator Project. Every project you set up gets its own orchestrator — the session that runs that project's work. I coordinate those orchestrators as needed:
- **Caretaking** — on request, I look after your other sessions and restart one that stalls or runs out of room.
- **Project management** — I set up projects, track what each one is doing and pass work between them.
- **Central configuration** — settings, tools and connections that all projects share live here.
- **Rules and knowledge** — the rules and know-how every project follows are kept and updated here.
- **Central backlog** — configuration work, and work that spans projects, goes into my backlog."

End that message with one question that checks understanding, e.g. "Does that split make sense — me coordinating, each project's session doing its own work?" If it does not land, explain again with an example from their world.

Next turn, invite a personal name the user can relate to: "You can give me a personal name, or keep calling me Coordinator. Sessions in your other projects call themselves '<project> Orchestrator' — e.g. 'research Orchestrator' in a project named research — because each one orchestrates its project's work; only this project is the Coordinator." If they decline, "Coordinator" stays. A personal name is used as is in every project; store it in `global/foundation/personas.md` as the persona with `Activates: default`.

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

Pick whatever you like — letters for persona, numbers for projects, X/Y/Z for setup. You can also just tell me more about yourself (job, education, interests) — it helps me work better for you. Or skip anything you're not interested in right now.
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

### 2e. Tool Suggestions (always, after the project types are picked)

Run `bash ~/agent-fleet/setup/scripts/kind-tools-check.sh <kinds>` with the kinds the user picked, mapped as: Code → `code`, Writing → `writing`, Research → `research`, Infrastructure → `infra`, Business → `business`, Data → `data`, Media → `media`. Marketing, Tooling and Custom have no own rows, so pass nothing for them. Tools everyone needs (fzf for the `af` picker, git, tmux, jq) are always checked. It prints each missing tool with the install command for this OS and why it matters (table: `setup/config/project-kind-tools.conf`). Show that list and offer to install. Install only what the user says yes to, and nothing at all without that yes; where the command needs `sudo`, hand it over as a `!` command.

### 2d. Service Connection (when user picks Y or Z)

Offer to connect external services via MCP:
- **Email:** Gmail, Outlook
- **Calendar:** Google Calendar — see the calendar offer below
- **Social:** Twitter/X, LinkedIn
- **Code:** GitHub, GitLab
- **Work tools:** Jira, Confluence, Slack

Each connection requires API keys or OAuth. Walk the user through setup one service at a time.

**Calendar offer** — made even when the user skipped Y/Z, as one question in its own turn: "Do you use a calendar you'd like me to work with — Google Calendar, something else, or none?"
- **Google Calendar** connects through the `google-workspace` MCP server, the calendar server the fleet ships (credentials as in step 3). Ask which of their calendars to use, or offer a separate one just for dated work. Once it works, dated future work — a deadline, a follow-up, a reminder — goes onto that calendar as an event titled `@<project> <what>` instead of a backlog line. Record the calendar's name and ID in `global/foundation/user-profile.md` under **Calendar**.
- **If none fits** — a calendar the fleet has no server for, or the user would rather not connect one — dated work goes into dated pending files: a `docs/pending-<topic>.md` in the owning project with a `Due: YYYY-MM-DD` line in its first five lines. Say so in one sentence, and that they can connect a calendar later ("connect my calendar").

### 2f. Document Store (always, one question per turn)

Some work products stay off git — scans, PDFs, large files, anything gitignored — and need a place that outlives a session. Ask one question: "Where do you keep documents you want to hold on to — a local folder, a NAS, Dropbox, or somewhere else?"
- **Local folder** — e.g. `~/Documents/fleet/`; simplest, but on this machine only.
- **NAS** — a network share mounted on each machine; reachable from all of them at home.
- **Dropbox** (or Google Drive, OneDrive) — synced across machines and the phone.
- **Something else** — whatever they already use; ask for the path or mount point.

The user picks; a combination is fine (e.g. NAS first, Dropbox for what they need on the go). Record each place as a row in `dms/storage-map.md` and mark the primary one in its Notes column — if the file does not exist yet, create it with the table from `docs/dms-guide.md` (step 4, "Define Storage Locations"). From then on, work products kept off git are filed there in the session that makes them. If the user skips the question, create nothing and ask again the first time a document needs a home; they can change the choice anytime ("move my documents").

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

**After selection:** Briefly explain what the user chose in concrete terms ("When you're frustrated, I'll switch to [secondary persona] — more patient, more validating. When things are calm, I'm [primary persona] — efficient and direct. You can say 'switch to [name]' anytime, or I'll detect the shift automatically."). Then ask if they want to name the personas or keep the defaults — as its own question, in its own turn.

**Names they can relate to:** invite the user to pick their own name for each persona — a nickname, a character, anything they can relate to. Example names, just to show the idea: "Gears" for the Workhorse and "Soft" for the Empath. A personal Coordinator name from step 1b is the natural name for the first persona of the pattern.

**Fallback when they decline:** the pattern-role names apply — "Coordinator Workhorse" + "Coordinator Empath" in the Coordinator Project, "<project> Workhorse" + "<project> Empath" in every other project (e.g. "research Workhorse"). Store them with the `<project>` placeholder; each session fills in its own project name.

**Key rule:** Always mention they can change personas anytime ("Just say 'change my persona' or 'I want a different style' and we'll reconfigure.")

For each persona, store in `global/foundation/personas.md`:
- **Name** — the display name
- **Traits** — comma-separated communication descriptors
- **Activates** — semantic rule (e.g., "default", "when frustrated")
- **Style** — free-text description

If the user declines: skip entirely, no persona section needed beyond a personal Coordinator name from step 1b. The system works without it.

### 3. Execute Selections

Process whatever the user chose from the menu above. For each:

**Persona:** Write to `global/foundation/personas.md`. Ask for persona names if they want custom ones — names they can relate to (e.g., "Gears" + "Soft" for Workhorse + Empath, as examples); otherwise use defaults, the pattern-role names from step 2b ("Coordinator Workhorse" + "Coordinator Empath" here). Briefly explain what they chose and mention they can change anytime.

**Project:** Create directory, initialize with `project-setup.md` template, add to `registry.md`, then run its `new-project.sh` step — that gives the project its MCP choice, `.gitignore` and its type's knowledge. Walk through any project-specific setup.

**Scan (X/Z):** Run infrastructure scan (step 2c above). Present findings, suggest projects based on what you find.

**Connect (Y/Z):** For each service, explain what credentials are needed and where to get them. Services available:
- **GitHub:** PAT with `repo` scope → https://github.com/settings/tokens
- **Gmail/Calendar/Drive:** Google Cloud OAuth → https://console.cloud.google.com/apis/credentials
- **Twitter/X:** Developer app → https://developer.x.com
- **Jira:** API token → https://id.atlassian.com/manage-profile/security/api-tokens
- **LinkedIn, Slack, Postgres:** credentials as needed

**Never ask the user to paste tokens in this chat session.** Session transcripts may be logged or cached, so a pasted token is a leaked token. Add each server entry to `~/.mcp.json` with a placeholder value and have the user put the real credential in with their own editor, or store it in the encrypted vault with `vault-manage.sh`. If a token is pasted anyway, tell the user to rotate it and treat it as compromised.

Update `~/.mcp.json` for each. Remind user to restart CC for new servers.

### 4. Features Showcase

After processing all selections, present a final overview of available capabilities. This is informational — no action needed from the user.

"You're all set. Here's what's available to you now — and what you can unlock later:

**Built-in capabilities:**
- **Backlog management** — every project gets a `backlog.md` with prioritized tasks, tracked automatically. No external tool needed. (If you use Jira, I can work with that too — it just costs more tokens per operation.)
- **Session memory** — I remember what we were doing across sessions, machines, and crashes. Two important commands: type `cls` to shut down cleanly and clear the screen (ready for a new session), or `end` to shut down and exit completely.
- **Document management** — I can catalog, organize, and track documents across your machines. PDFs, reports, research papers — filed and findable.
- **File management** — sorting, deduplication, bulk operations, cross-disk organization. Tell me about your file chaos and I'll help.
- **Cross-project coordination** — tasks flow between projects automatically via an inbox system.

**Available skills (activate by describing the problem):**
- **Simulation & optimization (SimOpt)** — discrete-event simulation for queueing, scheduling, resource allocation, throughput optimization. Say 'simulate' or describe a system with queues and servers.
- **Browser automation** — web scraping, form filling, testing, screenshot capture via Playwright. Say 'go to [url]' or 'take a screenshot'.
- **Self-audit (`lrn`)** — when something goes wrong, I analyze root causes and create prevention rules. Say `lrn` to trigger.

**Multi-machine & server (available now, set up on demand):**
- **Multi-machine sync** — same setup on office PC, laptop, home server, Steam Deck. Git-based, automatic.
- **Server deployment** — run agent fleet on a VPS for remote/mobile access via web terminal
- **Mobile access** — lightweight repo for managing projects from your phone

**Upcoming:**
- **Creative studio** — AI-assisted image generation, art direction, and visual content workflows
- **Full GUI** — desktop dashboard with visual project management, progress indicators, and persona face

Type `lsd` for a project dashboard anytime. Everything is documented — just ask."

### 5. Verification and Clean-Up

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
