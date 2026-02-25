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
- **Working Directory**: [path]
- **Session Goal**: [current high-level objective]

## Current State
- **Active Task**: [what you're currently working on]
- **Progress**: [completed steps]
- **Pending**: [remaining steps]

## Context
- **Key Files Modified**: [list of files changed this session]
- **Key Decisions Made**: [important choices and rationale]
- **Blockers/Issues**: [any problems encountered]

## Recovery Instructions
[If session terminates, here's how to resume:]
1. [Step to continue from current state]
2. [Next action needed]
3. [Any pending verifications]

## Conversation Summary
[Brief summary of what user asked and what was discussed]
```

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

### 2. Cross-project inbox
- [ ] If this session's work affects other projects, drop tasks in `~/claude-config/cross-project/inbox.md`
- [ ] Each entry targets ONE project — never broadcast
- [ ] Format: `- [ ] **project-name**: description of what they need to do`

### 3. Shared strategy files
- [ ] If shared state changed → update the relevant `~/claude-config/cross-project/*-strategy.md` file
- [ ] Only update strategy files you actually touched this session — don't speculatively refresh them

### 4. Auto memory (MEMORY.md)
- [ ] Save **durable lessons** confirmed this session (not session state)
- [ ] Patterns, gotchas, key facts that will save time in future sessions
- [ ] Keep MEMORY.md under 50 lines — use separate topic files for detail
- [ ] Never duplicate what's already in project docs or strategy files

### 5. Commit and push
- [ ] `git add` changed files, commit with descriptive message
- [ ] `git push` (or rely on SessionEnd auto-sync hook if configured)
- [ ] If domain-specific workflows apply (e.g., publication builds), follow their extended checklist

### 6. Verify auto-sync will succeed (if applicable)
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
