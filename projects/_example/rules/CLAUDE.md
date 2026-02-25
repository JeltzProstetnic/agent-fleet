# [Project Name] — Claude Manifest

Brief one-line description of what this project is.

## Knowledge Loading

| Domain | File | Load when... |
|--------|------|-------------|
| Software Development | `~/.claude/domains/software-development/tdd-protocol.md` | Writing or modifying code |

## Key Files

| File | Purpose |
|------|---------|
| `session-context.md` | Current session state — read first |
| `backlog.md` | Prioritized backlog — read when active TODOs are done |

## Project-Specific Rules

- [Any conventions specific to this project — language, framework, style]
- [Deployment or environment constraints]
- [Things Claude should never do in this project]

## Workflow

[Optional: describe the standard development loop for this project]

1. Read `session-context.md`
2. Pick up active tasks
3. Update `session-context.md` before and after significant actions
