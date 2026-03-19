# Cross-Project Boundary & Sync Rules

**Load this file when:** writing files outside current project, syncing between public/private repos, or using filtered push.

## Cross-Project Boundary Rule — HARD CONSTRAINT

You may ONLY write to files inside your current working project. Writing to ANY file in another project's directory is FORBIDDEN — even if you know the path, even if it seems convenient, even for "shared" files. The ONLY legal way to affect another project is through the cross-project inbox. Violations of this rule cause silent data corruption and task loss.

**No exceptions.** All cross-project communication — including template updates and sub-project `.claude/` maintenance — goes through the inbox. `sync.sh` may perform mechanical file copying as infrastructure automation (symlinks, stripped template copies), but all changes requiring judgment (commits, pushes, config decisions) go through the target project's own session via inbox tasks.

### Path Ownership (concrete mapping)

- `~/agent-fleet/*` and `~/.claude/*` — owned by the **config project**
- `~/<project>/*` — owned by that specific project (writable only when working in it)
- `~/agent-fleet/cross-project/inbox.md` — writable from any project (always)
- `~/agent-fleet/cross-project/contacts.md` — append-only from any project (new contacts, status updates)
- `~/agent-fleet/cross-project/*.md` strategy files — writable during shutdown only (see shutdown checklist)

Reading files and executing scripts from any project is always permitted. Only writing/editing files outside your current working project is forbidden (except the inbox and shutdown strategy files).

### Sibling Session Check — config repo pairs

When a private config repo has a paired public template repo (or vice versa), these two projects share `global/`, hooks, and `setup/scripts/`. The SessionStart hook injects `SIBLING_SESSION:` into systemMessage with the sibling project's session lock state.

- **`SIBLING_SESSION: none`** — No active session in the sibling project. Direct cross-project writes are permitted for this session (no inbox needed). Record this in session-context.md.
- **`SIBLING_SESSION: active (<machine>)`** — Sibling has an active session. Normal inbox protocol applies. Do NOT write to the sibling project.
- **Scope:** This override applies ONLY to recognized config repo sibling pairs. All other cross-project boundaries use the inbox unconditionally.
- **Audit trail:** When using direct write access, note "SIBLING_SESSION: none — direct write" in session-context.md and commit messages.

## Cross-Project Inbox

`~/agent-fleet/cross-project/inbox.md`
- The inbox is the ONLY mechanism for cross-project communication
- Tasks are per-project (one entry per project, not broadcasts)
- Pick up YOUR project's tasks, delete them from inbox after integrating
- To request changes in another project: write an inbox entry, NEVER edit their files directly
- Format: `- [ ] **target-project-name**: what needs to happen`

## Public/Private Sync Direction Rule

When a project has both public and private repos (e.g., a private config repo + a public template repo), diffs between them are NOT always bugs. Before syncing, classify each diff: (1) **intentional personalization** — private has personal names/accounts/paths, public has generic placeholders → leave both as-is; (2) **structural improvement in private** that public should get → propagate after stripping personal details; (3) **public-only change** → backport to private. Never blindly sync private→public — that leaks personal data. Never blindly sync public→private — that overwrites intentional customizations.

## Dual-Remote Push Rule — HARD CONSTRAINT

For projects with a filtered public remote (identified by `.push-filter.conf` in project root): NEVER `git pull`, `git fetch --merge`, or `git merge` from the public remote into the working branch. The public remote is **write-only** — it contains a filtered subset and merging it contaminates the working tree (deletes files that were intentionally excluded). Only pull/merge from the private remote. Push to public ONLY via `bash ~/agent-fleet/setup/scripts/filtered-push.sh`. If `git-sync-check.sh` runs in a dual-remote project, it must ONLY sync with the private remote, never the public one.
