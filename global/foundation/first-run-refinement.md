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

### 3. Select Relevant Domains

Read `global/domains/INDEX.md`. Show the available domains:

- **Software Development** — TDD protocol, code quality patterns
- **Publications** — Markdown-to-PDF pipeline, test-driven authoring
- **Engagement** — Twitter/X engagement protocol
- **IT Infrastructure** — Servers, Docker, DNS, deployment

Ask: "Which of these match what you do? You can also describe domains you need that aren't here yet."

Note their selections — they'll use these when setting up projects.

### 4. Set Up First Project (Optional)

Ask: "Do you have a project you'd like to configure now? If so, what's the directory path?"

If yes:
1. Read the project directory to understand what it is
2. Create a `CLAUDE.md` manifest for it (use the template in `projects/_example/rules/CLAUDE.md`)
3. Add it to `registry.md`
4. Create an initial `session-context.md` in the project
5. Deploy the rules: copy the manifest to `<project>/.claude/CLAUDE.md`

If no: explain how to do it later ("just open Claude in any project directory and say 'set up this project'").

### 5. Customize Global Prompt (If Needed)

Ask: "Any rules you want Claude to always follow across all projects?"

Examples to prompt:
- Output preferences (language, format)
- Tool preferences ("always use bun instead of npm")
- Safety preferences ("always ask before committing")
- Style preferences ("keep responses short")

If they have preferences, add them to the Conventions section of `global/CLAUDE.md`.

### 6. Verify and Clean Up

- Run `bash sync.sh status` to verify everything is linked correctly
- Delete the `.setup-pending` marker file
- Create an initial `session-context.md` for the config repo itself
- Commit everything: "Initial configuration after interactive setup"

### 7. Summary

Tell the user:
- What was configured
- How to sync across machines (`git push` from here, `git pull` + `bash sync.sh setup` on the other machine)
- How to add more projects later
- How to customize further (edit files in this repo, then `bash sync.sh deploy`)

## Important

- **Be conversational**, not robotic. This is onboarding, not a form.
- **Skip steps the user doesn't care about.** If they say "just coding, nothing fancy" — don't push domains, customization, etc.
- **Keep it under 10 minutes.** Don't over-explain. The system is self-documenting.
- **Delete `.setup-pending`** when done. This protocol should only run once.
