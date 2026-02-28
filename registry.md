# Project Registry

The phone book for all projects and machines. Read this when a user mentions a project by name.

## Machines

| Machine | Description | Notes |
|---------|-------------|-------|
| [machine-name] | [e.g., "primary workstation", "home server"] | [OS, special roles] |

## Projects

**Priority scale:** P1 = critical/daily, P2 = active/weekly, P3 = ongoing/as-needed, P4 = paused, P5 = dormant/archive candidate

| Project | Priority | Path | Description | Active |
|---------|----------|------|-------------|--------|
| agent-fleet | P1 | `~/agent-fleet/` | Claude Code configuration management | yes |

## Adding a Project

1. Create `projects/<name>/rules/CLAUDE.md` in this repo
2. Add a row to the Projects table above
3. Run `bash sync.sh deploy` to push rules to the project path
4. Create `session-context.md` in the project root

## Conventions

- **Path**: canonical location on the primary machine
- **Active**: `yes` = currently in use, `no` = archived or paused
