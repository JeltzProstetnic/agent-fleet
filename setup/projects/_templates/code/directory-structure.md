# Code Project — Directory Structure

```
{{PROJECT_NAME}}/
├── src/                 # Source code
├── tests/               # Test files
├── scripts/             # Build, deploy, utility scripts
├── docs/                # Documentation, session log
│   └── session-log.md   # Full session archive
├── tmp/                 # Build artifacts, throwaway (gitignored)
├── .claude/             # Agent config
│   └── settings.local.json
├── session-context.md   # Current session state
├── backlog.md           # Prioritized backlog
└── CLAUDE.md            # Project manifest
```

## Key Conventions

- Source layout depends on tech stack (adjust `src/` accordingly)
- Tests mirror source structure
- `tmp/` is gitignored
- `docs/` is for project docs, not code docs (those live with code)
