# Cross-Project Sync — Shared Strategy Pattern

**Load when:** Two or more projects need coordinated state, shared targets, or synchronized timing on overlapping concerns.

---

## When to Use This Pattern

Projects sometimes overlap in scope but differ in channel or phase:

| Project A | Project B | Overlap |
|-----------|-----------|---------|
| Authoring/academic | Marketing/engagement | Same targets, different channels |
| Backend | Frontend | Shared API contracts, deployment timing |
| Research | Implementation | Research findings feed implementation decisions |

**Symptoms that sync is needed:**
- Same person/target tracked in both projects with different status
- One project makes decisions that affect the other without visibility
- Duplicate backlog items diverging over time
- Timing-sensitive actions in one project that depend on state in the other

---

## The Pattern

### 1. Create a shared strategy file

Location: `~/agent-fleet/cross-project/<name>-strategy.md`

This file is the **single source of truth** for anything that spans both projects. Neither project duplicates this content in their own backlog.

### 2. Structure of a shared strategy file

```markdown
# [Name] Strategy — Unified Cross-Project

**Shared between:** `~/project-a` and `~/project-b`
**Last updated:** [date]

## Stance / Principles
[High-level decisions that govern both projects]

## Channel Roles
[Which project owns which channel/activity]

## Unified Target List
[All shared targets with status across ALL channels]

## Calendar / Deadlines
[Single source of truth for time-sensitive items]

## Coordination Rules
[When to check the other project before acting]

## Sync Protocol
[How and when to update this file]
```

### 3. Update project backlogs

Each project's backlog should:
- **Reference** the shared strategy file at the top
- **Keep only project-specific tasks** — things only that project does
- **Remove duplicates** — if it's in the shared file, don't repeat it
- **Note ownership transfers** — "This item is owned by [other project], see strategy file"

### 4. Coordination rules

The shared strategy file should define rules like:
- Before acting on a shared target in channel A, check status in channel B
- Timing dependencies (e.g., "don't tweet at X if we emailed them < 2 weeks ago")
- Escalation path (if one project discovers something that affects the other)

### 5. Update discipline

When either project modifies anything in the shared file's scope:
1. Update the shared strategy file (not just the project backlog)
2. If the change affects the other project's next actions, drop a note in the cross-project inbox

---

## What Goes Where

| Content | Location | Why |
|---------|----------|-----|
| Shared targets + status | Strategy file | Single source of truth, prevents divergence |
| Project-specific tasks | Project backlog | Only that project acts on them |
| One-off cross-project tasks | `~/agent-fleet/cross-project/inbox.md` | Transient, picked up and deleted |
| Persistent shared state | Strategy file | Survives across sessions |
| Detailed dossiers/profiles | Owning project's `tmp/` or `docs/` | Too detailed for the strategy overview |

---

## Anti-Patterns

- **Don't duplicate shared state in both backlogs.** It will diverge within 2 sessions.
- **Don't use the inbox for persistent state.** Inbox items get deleted after pickup. Strategy files persist.
- **Don't create a strategy file for trivial overlap.** If it's just one shared deadline, put it in the inbox. The pattern is for sustained, multi-dimensional coordination.
- **Don't let the strategy file grow unbounded.** It's an overview with status, not a detailed dossier. Link to detailed docs in the owning project.
