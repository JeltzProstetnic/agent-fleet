# Writing Project — Directory Structure

```
{{PROJECT_NAME}}/
├── manuscript/          # Main manuscript source (.md files)
│   └── chapters/        # Chapter files (if book-length)
├── figures/             # Diagrams, images, renders
├── scripts/             # Build scripts, push scripts
├── docs/                # Session log, decisions, notes
│   └── session-log.md   # Full session archive
├── drafts/              # Content awaiting user action (tracked)
├── tmp/                 # Build output, tests, throwaway (gitignored)
├── .claude/             # Agent config
│   └── settings.local.json
├── session-context.md   # Current session state
├── backlog.md           # Prioritized backlog
├── references.md        # Master reference list
└── CLAUDE.md            # Project manifest
```

## Key Conventions

- `manuscript/` is the single source of truth for content
- `tmp/` is gitignored — never store important work there
- `drafts/` is tracked — content here persists across machines
- Build output goes to `tmp/` (e.g., `tmp/build-output/`)
- Session artifacts (context, log) live at project root
