# Business Project — Directory Structure

```
{{PROJECT_NAME}}/
├── data/                # Source data, reports, analysis inputs
├── knowledge/           # People KB, domain knowledge
│   └── people.md        # Key contacts and stakeholders
├── docs/                # Findings, decisions, session log
│   ├── session-log.md   # Full session archive
│   └── decisions.md     # Curated decisions & rationale
├── drafts/              # Reports, presentations awaiting review
├── tmp/                 # Throwaway artifacts (gitignored)
├── .claude/             # Agent config
│   └── settings.local.json
├── session-context.md   # Current session state
├── backlog.md           # Prioritized backlog
└── CLAUDE.md            # Project manifest
```

## Key Conventions

- `data/` for inputs, `docs/` for outputs/analysis
- `knowledge/people.md` tracks stakeholders and contacts
- `drafts/` for content awaiting user review (tracked in git)
- `tmp/` is gitignored
