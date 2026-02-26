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

```markdown
# Session Context

## Session Info
- **Last Updated**: [ISO timestamp]
- **Machine**: [machine-id]
- **Working Directory**: [path]
- **Session Goal**: [current high-level objective]

## Current State
- **Active Task**: [what you're currently working on]
- **Progress** (use `- [x]` checkbox for each completed item):
  - [x] Example completed step
  - [ ] Example pending step
- **Pending**: [remaining steps]

## Key Decisions
- [Decision]: [rationale] (record significant decisions made this session)

## Recovery Instructions
[If session terminates, here's how to resume:]
1. [Step to continue from current state]
2. [Next action needed]
3. [Any pending verifications]
```

## Session Documentation Layers

Session information is organized in 3 layers to balance startup speed with history preservation:

| Layer | File | Read at startup? | Purpose |
|-------|------|-------------------|---------|
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

## Session Shutdown Checklist — MANDATORY

**Before every session end, run through this checklist in order:**

### 1. Session context
- [ ] Update `session-context.md` with final state, completed work, and recovery instructions

### 2. Session rotation
- [ ] Run `bash ~/claude-config/setup/scripts/rotate-session.sh` to archive session to history/log and reset template
- [ ] If significant decisions were made, add entries to `docs/decisions.md`

### 3. Cross-project inbox
- [ ] If this session's work affects other projects, drop tasks in `~/claude-config/cross-project/inbox.md`
- [ ] Each entry targets ONE project — never broadcast
- [ ] Format: `- [ ] **project-name**: description of what they need to do`

### 4. Shared strategy files
- [ ] If infrastructure, deployment, or shared state changed → update `~/claude-config/cross-project/infrastructure-strategy.md`
- [ ] If visibility/outreach state changed → update `~/claude-config/cross-project/fmt-visibility-strategy.md`
- [ ] Only update strategy files you actually touched this session — don't speculatively refresh them

### 5. Machine knowledge
- [ ] If machine-specific state changed (tooling installed, patches applied, auth rotated) → update `~/.claude/machines/<machine>.md`
- [ ] If new operational knowledge discovered (tool bugs, workarounds) → update or create `~/.claude/knowledge/<tool>.md`

### 6. Commit and push
- [ ] `git add` changed files, commit with descriptive message
- [ ] `git push` (or rely on SessionEnd auto-sync hook if configured)
- [ ] If publication files were modified, follow the extended checklist in `publication-workflow.md` Section 6

### 7. Verify sync (if applicable)
- [ ] Run `bash ~/claude-config/sync.sh collect` to verify it exits cleanly
- [ ] If it fails, fix the issue or clear `.sync-failed` marker with explanation

**The user must be able to open consistent, up-to-date files after the session ends.** Stale context, missing inbox tasks, or outdated strategy files are unacceptable.

## Implementation Rules

1. **Always check for existing session-context.md on session start** - if found, read it to understand prior context
2. **Never skip updates** - even for quick tasks, maintain the context file
3. **Be concise but complete** - future you (or a new session) should be able to resume work
4. **Include recovery instructions** - assume the session could terminate at any moment
5. **Update BEFORE responding** - write state before action, update after completion
6. **Reference, don't duplicate** - point to canonical docs rather than copying their content
7. **Session-context.md MUST be populated before rotation** - `rotate-session.sh` will refuse to archive a blank template. At minimum, fill in `Session Goal` (even if just "No significant activity — quick check") and one line under Progress or Key Decisions explaining what happened. If a session genuinely did nothing, write that explicitly — a blank template is never acceptable.
