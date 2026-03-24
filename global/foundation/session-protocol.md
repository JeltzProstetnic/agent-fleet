# Session Context Persistence — MANDATORY

**You MUST maintain a `session-context.md` file in the current working directory** to ensure continuity in case of power loss, crash, or session termination.

## Location

The session context file should be at: `./session-context.md` (relative to current working directory)

## When to Update

1. **At session start**: Read existing `session-context.md` if present, then update with new session timestamp
2. **Before each user interaction**: Update with current state before responding
3. **After each user interaction**: Update with completed actions and next steps
4. **Before any significant operation**: Checkpoint current progress

## Required Content Structure

Use the exact template from `session-context.md` (reset by `rotate-session.sh`). Required fields: `**Session Goal**:` inline, `- [x]` checkboxes for completed items, `## Key Decisions` section. The rotation script parses these programmatically — freeform headings or plain bullets won't be detected.

## Session Documentation Layers

Session information is organized in 3 layers to balance startup speed with history preservation:

| Layer | File | Read at startup? | Purpose |
|-------|------|-------------------|---------|
| 0 | `next-session-task.md` | YES — if exists | Previous session's task handoff |
| 0b | `docs/pending-*.md` | YES — scan | Multi-file handover from previous sessions |
| 1 | `session-context.md` | YES | Current session state |
| 2 | `session-history.md` | NO — on demand | Rolling last 3 sessions |
| 3a | `docs/session-log.md` | NO — reference only | Full archive, never pruned |
| 3b | `docs/decisions.md` | NO — on demand | Curated decisions & rationale |

**Layer 1 (session-context.md):** Current session only. Read at startup, updated throughout, archived at shutdown by the rotation script.

**Layer 2 (session-history.md):** Rolling window of the last 3 sessions. Newest first. Read when you need recent context (e.g., "what happened last session?"). Managed automatically by `rotate-session.sh`.

**Layer 3a (docs/session-log.md):** Full chronological archive. Every session ever, append-only, never pruned. Same entry format as Layer 2. Read when you need to look back further than 3 sessions.

**Layer 3b (docs/decisions.md):** Curated, topic-organized record of important decisions, user requirements, and design rationale. Manually maintained — add entries during sessions when significant decisions are made. NOT automated at shutdown.

**decisions.md vs CLAUDE.md:** No overlap. CLAUDE.md contains rules (behavioral directives). decisions.md contains rationale, context, and choices that don't translate to rules.

## Relationship to Auto Memory and Project Docs

**session-context.md** and **MEMORY.md** (auto memory) serve different purposes:

| | session-context.md | MEMORY.md (auto memory) |
|---|---|---|
| **Scope** | Current session only | Persists across all sessions |
| **Contains** | Active task, progress, recovery steps | Durable lessons, project orientation |
| **Reset** | Fresh each session | Accumulates over time |

**Anti-duplication rules:**
- **NEVER copy project facts into session-context.md** - reference `PROJECT.md`, `ARCHITECTURE.md`, etc. instead
- **NEVER copy session state into MEMORY.md** - that's what session-context.md is for
- **MEMORY.md should be <50 lines** - just enough to orient a cold start, with pointers to canonical docs
- If information exists in a project doc, **link to it, don't repeat it**

## Session Shutdown

The shutdown checklist is in `foundation/session-shutdown.md` — loaded on demand when `cls`, `end`, or shutdown is triggered. Not loaded at startup to save tokens.

## Implementation Rules

1. **Always check for existing session-context.md on session start** - if found, read it to understand prior context
2. **Never skip updates** - even for quick tasks, maintain the context file
3. **Be concise but complete** - future you (or a new session) should be able to resume work. If a subagent or exploration produced a significant work product (dependency map, architecture analysis, research findings), persist it to a file immediately — don't just reference it in session-context.md. Conversation context dies with the session; files survive.
4. **Include recovery instructions** - assume the session could terminate at any moment
5. **Update BEFORE responding** - write state before action, update after completion
6. **Reference, don't duplicate** - point to canonical docs rather than copying their content
7. **Session-context.md MUST use the exact template format** — `rotate-session.sh` parses it programmatically. Required: `**Session Goal**:` inline (not a heading), `- [x]` checkboxes for completed items, `## Key Decisions` section heading. Do NOT use freeform headings like `## What Was Done` or plain bullets without checkboxes — the rotation script won't detect them and will refuse to archive. At minimum: fill in Session Goal + at least one `- [x]` item or one decision under Key Decisions.
8. **Cross-session task handoff:** Add `## Next Session Task` to session-context.md with `task: true`, `file:`, and `description:`. Rotation extracts it to `next-session-task.md`. **HARD RULE: `file:` must NEVER point to `session-context.md`** — rotation blanks it, so the next session would find an empty file. Always write handoff data to a dedicated file in `docs/` (e.g., `docs/pending-<task>.md`) and point `file:` there. Never use `tmp/` — handoff files must persist across machines via git. This includes task lists, pending updates, execution plans — anything the next session needs to act on. **Restart-required verifications ARE handoff tasks** — if a fix can only be verified after restart (MCP changes, auth changes, hook changes), write it to next-session-task.md with explicit verification steps. Never put restart verifications in freeform "Recovery/Next session" text alone.
9. **Dangling references:** Rotation warns on "see below"/"see ##"/"(below)" — save referenced content to a file first.
10. **Pending file carry-over (Layer 0b):** Check `PENDING_FILES:` in systemMessage. If `none`, skip. If listed, those `docs/pending-*.md` files exist and must be processed:
    - **Read the `Action:` line** in each file's header (see format below). If no header exists, treat as `triage`.
    - **`present`** → Read fully, include in opening response to user. These are session-start deliverables.
    - **`act`** → Promote to backlog, create inbox items if cross-project, transition to `reference` with `Tracked-by:`.
    - **`triage`** → Read, promote actionable items to backlog as P0, then delete file.
    - **`await-user-decision`** → Read, present decision needed to user, note in carry-over items.
    - **`defer`** → List in session-context.md carry-over items without reading fully. No action needed.
    - **`reference`** → Skip at startup. Do not read or present. Only read when actively working on a `Tracked-by` backlog item and needing deeper context. Delete the file when ALL `Tracked-by` items are closed (`- [x]` in backlog).
    - Files without an `Action:` line default to `triage` — read them to determine what's needed.
    - List all pending files and their outcomes in session-context.md under `## Carry-Over Items`.
    - Pending files are deleted after their items are fully resolved or promoted to backlog.
    - **Pending file header format:** `Action: present|act|triage|await-user-decision|defer|reference` as the first non-comment, non-title line.
    - **Pending file intake — backlog promotion.** When promoting a pending file's content (findings, tasks, action items) to backlog entries, immediately: (1) add a `Tracked-by: CFG-xxx, CFG-yyy` header line listing all created backlog IDs, (2) strip any status-tracking content from the file (checklists, "Done:"/"Open:" lists, completion markers) — leave only analysis/context, (3) change `Action:` to `reference`.
    - **Resolved `await-user-decision` files:** When a session resolves the decisions an `await-user-decision` file tracks (by executing the work, getting user answers, or making the question moot), the file MUST be updated or deleted before shutdown. Shutdown step 1 should verify: check all remaining `await-user-decision` pending files and confirm their tracked items are still open. Stale decision files cause the next session to re-present already-answered questions.
