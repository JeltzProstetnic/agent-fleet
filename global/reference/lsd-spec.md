# `lsd` — Project Dashboard Spec

**STRICT FORMAT — follow exactly. Do NOT improvise or simplify.**

## 1. Data Collection — Cache-First

Read `~/agent-fleet/cross-project/dashboard-cache.md`. This file contains pre-computed task counts, disk sizes, and deadlines for all projects. It is updated by:
- **Session shutdown** — each project updates its own row when shutting down
- **`lsd refresh`** — runs `bash ~/agent-fleet/setup/scripts/lsd-refresh.sh` to do a full scan of all local backlogs and disk sizes

Show P1-P3 by default, P1-P5 with `lsd all`. Do NOT scan backlogs or run `du` — trust the cache. If the cache is missing, run `lsd-refresh.sh` once.

## 2. Display Format — Separate Table Per Priority Tier

Each tier gets its own box-drawing table with a tier header. This is the key visual structure — do NOT merge tiers into one big table.

**Box-drawing tables are preferred.** Use Unicode box-drawing characters (┌─┬─┐ │ ├─┼─┤ └─┴─┘). Each tier rendered as a standalone table.

**Column structure — 5 columns per table:**

```
┌────┬──────────────────┬──────────────┬──────────────────────────────────────┬──────┐
│  # │ Name             │ Type         │ Tasks                                │ Size │
├────┼──────────────────┼──────────────┼──────────────────────────────────────┼──────┤
│  1 │ my-project       │ code (p)     │ 3P1 1P2 4P3 — Fix auth; Deploy      │ 1.2G │
│    │  +- sub-proj     │ library      │ 1P2                                  │ 340M │
│    │  +- docs-site    │ docs         │ 2P3                                  │    — │
│  2 │ config-repo      │ meta/config  │ 2P2 1P3                              │   5M │
│    │  +- template     │ template     │ 2 open                               │ 128K │
│  3 │ social-project   │ engagement   │ 1P1 12P2 5P3 — Post campaign         │ 544K │
└────┴──────────────────┴──────────────┴──────────────────────────────────────┴──────┘
```

**Tier headers** — bold text above each table: `**[P1] CRITICAL**`, `**[P2] ACTIVE**`, `**[P3] ONGOING**`

**Path column removed** — paths are predictable (`~/project-name`), removing them saves width for the Tasks column which needs room for P1 names.

**Sub-projects** render directly under their declared parent (per the Parent column in the cache). Children use tree characters for visual hierarchy. Children get **lowercase letters** (a, b, c...) as selectors, indented from parent numbers for visual separation. Promoted children (child priority < parent priority) get their own **number** at their priority tier with `(parent)` suffix on type. **Blank lines** separate parent groups (parent + its children = one group, then blank line, then next group).

**Dynamic column widths — MANDATORY for all columns.** Follow this algorithm for EVERY tier table:

1. **Truncate first.** For each cell, if content exceeds the column maximum, cut to `max - 1` chars and append `…`. Do this BEFORE measuring widths. Maximums: `#`=2, Name=24, Type=20, Tasks=50, Size=14.
2. **Measure.** After truncation, find the longest content in each column across all rows in the tier.
3. **Clamp.** Set column width to `max(minimum, measured_width)`. Minimums: `#`=2, Name=16, Type=12, Tasks=20, Size=6.
4. **Pad.** Pad all cells to their column width. Right-align Size values.

**Truncation is non-negotiable.** If a Type value is `research + authoring + code (p)` (31 chars) and the max is 20, render it as `research + author…`. No cell may ever exceed its column maximum.

**Task counts** use compact format: `3P1 1P2 4P3` (only show priorities that have items). If no backlog or not local: `—`.

**P1 task names:** When a project has P1 tasks, show their names in the Tasks column after the counts: `2P1 1P2 — Fix auth bug; Deploy hotfix`. The cache has a `P1Names` column (pipe-separated). Render as semicolon-separated after an em dash.

**Last completed item:** When a project has no open tasks (Tasks = `—`) but has a backlog with completed items, show the most recent one in italics in the Tasks column: `*Shipped v3.0*`. The cache has a `LastDone` column. Only show when Tasks would otherwise be `—`.

**Type indicators** append in parentheses: `(d)` = dual-push, `(p)` = public+private pair.

**Deadline flags**: append `!!` + description to the Size column: `544K !! Mar 15`.

**Color note:** ANSI colors cannot render in Claude Code chat output (markdown renderer strips them). Box-drawing and bold text are the available visual tools. The statusline is the only surface with ANSI color support.

**Reference rendering** (example with fake data — follow this structure exactly):

**[P1] CRITICAL**
```
┌────┬──────────────────┬──────────────┬──────────────────────────────────────────────┬──────────────┐
│  # │ Name             │ Type         │ Tasks                                        │ Size         │
├────┼──────────────────┼──────────────┼──────────────────────────────────────────────┼──────────────┤
│  1 │ my-project       │ research (p) │ 3P1 1P2 4P3 — Submit abstract; Fix; Review   │ 1.2G         │
│    │  +- sub-module   │ code         │ 1P2                                          │ 340M         │
│    │  +- test-suite   │ code         │ 2P3                                          │    —         │
│  2 │ config-repo      │ meta/config  │ 2P2 1P3                                      │   5M         │
│    │  +- template     │ template     │ 2 open                                       │ 128K         │
│  3 │ social-project   │ engagement   │ 1P1 12P2 5P3 — Post campaign                 │ 544K !! M.15 │
└────┴──────────────────┴──────────────┴──────────────────────────────────────────────┴──────────────┘
```

**[P2] ACTIVE**
```
┌────┬──────────────────┬──────────────┬──────────────────────────────────────────────┬──────┐
│  # │ Name             │ Type         │ Tasks                                        │ Size │
├────┼──────────────────┼──────────────┼──────────────────────────────────────────────┼──────┤
│  4 │ creative-proj    │ code         │ *Shipped v2.0 gallery*                       │ 2.1G │
│  5 │ data-pipeline    │ code (d)     │ 1P3                                          │    — │
│  6 │ corporate-tools  │ tooling      │ —                                            │    — │
│    │  +- compliance   │ business     │ —                                            │    — │
│  7 │ infrastructure   │ infra        │ —                                            │    — │
└────┴──────────────────┴──────────────┴──────────────────────────────────────────────┴──────┘
```

**[P3] ONGOING**
```
┌────┬──────────────────┬──────────────┬──────────────────────────────────────────────┬──────┐
│  # │ Name             │ Type         │ Tasks                                        │ Size │
├────┼──────────────────┼──────────────┼──────────────────────────────────────────────┼──────┤
│  8 │ side-project     │ code         │ 1P3                                          │  45M │
│  9 │ search-engine    │ infra        │ —                                            │    — │
└────┴──────────────────┴──────────────┴──────────────────────────────────────────────┴──────┘
```

After the tables: `+ N paused/dormant (lsd all)` if P4-P5 projects were omitted.

## 3. Actions

After the table, show:

`switch <N>` Open project in new tab | `details <N>` Full project info | `new` Create new project | `all` Show P4-P5 too | `refresh` Re-scan all backlogs and disk sizes

- **switch**: archive current session-context.md, open new terminal tab in that project's directory (platform-aware: Konsole D-Bus on KDE, tmux on VPS, wt.exe on WSL)
- **details**: show full info including machines, GitHub remotes, agents, multi-repo setup
- **new**: follow project-setup.md
- **all**: re-display including P4-P5 projects
- **refresh**: run `bash ~/agent-fleet/setup/scripts/lsd-refresh.sh`, then re-display
