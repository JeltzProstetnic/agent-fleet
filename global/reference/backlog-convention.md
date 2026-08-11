# Backlog Convention — Full Reference

Load this when: creating a new project backlog, managing task IDs, or reviewing prioritization rules.

## Format

Every project has `backlog.md` at root. Do NOT read at session start — only when active tasks are done or user asks.

```
# Backlog — <project-name>

## Open

- [ ] [P1] `PRJ-01` **Task title**: Description
- [>] [P0] `PRJ-02` **Active task**: Being worked on right now

## Done

### YYYY-MM-DD (most recent session only)
- [x] Completed task description

Older completed items: `docs/backlog-archive.md`
```

## Task States

| Marker | State | Meaning |
|--------|-------|---------|
| `- [ ]` | Open | Available for work |
| `- [>]` | In-progress | A session is actively working on this |
| `- [x]` | Done | Completed |

**In-progress rule:** Mark `[>]` when implementation begins (not at planning/triage). Revert to `[ ]` at shutdown if work is incomplete. Defense in depth — a session must forget both marking in-progress AND marking done for a stale item to resurface.

## Task IDs

Every open task gets a stable ID: `PRJ-NN` where `PRJ` is a short project prefix (2-4 uppercase letters) and `NN` is a zero-padded sequential number. IDs are unique within a project — never reused, even after completion. The user can reference tasks by ID across sessions.

Standard prefixes:

| Prefix | Project |
|--------|---------|
| `AFT` | agent-fleet (this repo) |
| `INF` | infrastructure |
| `DOC` | docs-site |
| `API` | api-service |
| `WEB` | web-app |

The rows below `AFT` are illustrative — replace them with your own projects. Pick a
2-4 letter prefix per project, keep it stable once used (IDs are never reused), and
add it to this table.

## Keep Backlogs Lean

Only the last session's Done section stays in `backlog.md`. Older completed items move to `docs/backlog-archive.md` (append-only, oldest first). This prevents backlogs from growing into multi-hundred-line token sinks.

## Project Prioritization

Registry has a `Priority` column (P1-P5). Backlog tasks carry a priority tag.

- **Project priority** (in `registry.md`): P1 = critical/daily, P2 = active/weekly, P3 = ongoing/as-needed, P4 = paused, P5 = dormant
- **Task priority** (in backlogs): prefix task line with `[P1]`-`[P5]`, e.g. `- [ ] [P1] `PRJ-01` **Fix deployment bug**: Description`. Untagged tasks default to P3.
- **Cross-project ranking**: sort by project priority first, then task priority within each project. A P2 task in a P1 project outranks a P1 task in a P3 project.
- **Open section**: flat list sorted by priority (P1 first), no subsections. Keep it scannable.
- **Done section**: group by date, most recent first. Move tasks here when completed — don't delete them.

## Grooming

Backlog grooming is a periodic cleanup task. When grooming (manually or via subagent), **all** of the following must happen:

1. **Move completed items**: All `[x]` items from Open → Done, grouped by date.
2. **Priority updates**: Actively re-assess and **change** priority levels based on:
   - **Roadmap alignment**: items on the critical path for current-quarter epics get bumped up; items for future-quarter epics stay lower.
   - **Dependency changes**: if a blocker was cleared (e.g., CFG-56 done → CFG-60 unblocked), the unblocked item may warrant a priority bump.
   - **Completion landscape**: when related work is done, remaining items may become more or less urgent (e.g., most of a storage block is done → the verification step is now the bottleneck).
   - **Strategic shifts**: user priorities, external deadlines, or new information that changes what matters.
   - **Blocked items**: items blocked on external factors (hardware, user action, another machine) should be demoted until unblocked.

   Do not just **flag** misalignments — actually **update** the `[Pn]` tags. The grooming notes should document what changed and why, not just suggest changes.

3. **Stale/obsolete check**: Remove or archive items that are no longer relevant.
4. **Duplicate consolidation**: Merge overlapping items.
5. **Formatting cleanup**: Consistent format, no stray blank lines.
6. **Re-sort**: After priority changes, re-sort the Open section by priority (P0 → P4).

## Pre-Creation Checks

Before creating a new backlog item `PRJ-NN`:

1. **Dedup check.** Search both Open and Done sections for the same topic. `grep -i "keyword" backlog.md`. If a match exists, update the existing item instead of creating a new one.
2. **Related item scan.** Identify items that are co-dependent, share a subsystem, or would benefit from being worked together. Link them: `Depends: CFG-XX` or group under the same `Epic: E-XX`.
3. **Cherry-pick rule.** When extracting ideas from an evaluation (competitor analysis, tool research, etc.), cross-check EVERY idea against Done items — completed work is invisible under momentum.

## Epic References

Backlog items link to strategic epics defined in `docs/roadmap.md`. Add `Epic: E-XX` at the end of the item description to connect it to the roadmap.

- Format: `Epic: E-01` or `Epic: E-01, E-06` (multiple)
- Epics group related backlog items under a strategic theme
- The roadmap file defines epic scope, vision stage, and dependencies
- Not every item needs an epic — small fixes and maintenance can stand alone
