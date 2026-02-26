# Operational Knowledge — Index

Conditionally loaded files containing operational knowledge for specific tools and skills. Not loaded at startup — only when triggered by context (see global CLAUDE.md conditional loading section).

## How It Works

1. Files here are reference material for specific tools/skills
2. Load them only when a task requires that tool or skill
3. Update during sessions when you discover workarounds, bugs, or operational insights
4. If a gotcha is discovered, add it to the relevant file

## Files

| File | Trigger | Content |
|------|---------|---------|
| (add entries as you create knowledge files) | | |

## Adding New Knowledge Files

1. Create `<tool-or-skill>.md` in this directory
2. Add a conditional loading entry in `global/CLAUDE.md` (see "Conditional loading" section)
3. Update this INDEX
4. Format: filename is lowercase, hyphens for spaces (e.g., `dev-browser-ops.md`)
