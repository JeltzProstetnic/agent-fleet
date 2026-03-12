# Session Shutdown Checklist — MANDATORY

**Before every session end, run through this checklist in order:**

### 0. Clean stale permissions
- [ ] Run `bash ~/cfg-agent-fleet/setup/scripts/clean-permissions.sh` — removes "Always allow" permission blocks from project settings.local.json files that shadow global permissions and cause prompt storms during shutdown

### 1. Session context and work products
- [ ] **Persist work products first.** If this session produced significant artifacts (maps, analysis results, generated data, exploration outputs, plans) that exist only in conversation context, write them to files NOW — before they're lost with the session. Recovery instructions that say "reference the X from this session" are worthless if X was never saved. Common culprits: subagent outputs, exploration results, dependency maps, architecture diagrams.
- [ ] **Clean completed pending files.** Check all `docs/pending-*.md` — if the work a file describes was completed this session, delete it. If a pending file is also a handoff target (`next-session-task.md` → `file:`), clear the handoff too (`task: false`). Stale pending files cause the next session to re-propose finished work.
- [ ] Update `session-context.md` with final state, completed work, and recovery instructions
- [ ] Update this project's row in `~/cfg-agent-fleet/cross-project/dashboard-cache.md` — task counts (grep backlog), disk size (`du -sh`). Only update fields that changed.

### 2. Session rotation
- [ ] Run `bash ~/cfg-agent-fleet/setup/scripts/rotate-session.sh` to archive session to history/log and reset template
- [ ] If significant decisions were made (check: does session-context `## Key Decisions` have 2+ items?), promote them to `docs/decisions.md` before commit
<!-- NEEDS TOKEN EFFICIENCY CHECK: decisions.md promotion reminder added 2026-03-05. Could be a hook that greps session-context.md. -->

### 3. Cross-project inbox
- [ ] **Mark completed inbox items `[x]`.** Check `~/cfg-agent-fleet/cross-project/inbox.md` for any `[ ]` items targeting THIS project that were completed this session. Mark them `[x]`. This is mandatory — stale unchecked items cause the next session to re-propose already-finished work. **Infrastructure/connectivity tasks require end-to-end verification** (e.g., `ssh ... echo test`, `curl -sI`, `deploy && verify`) — script fixes + backlog tracking alone do NOT count as completion.
- [ ] If this session's work affects other projects, drop tasks in `~/cfg-agent-fleet/cross-project/inbox.md`
- [ ] Each entry targets ONE project — never broadcast
- [ ] Format: `- [ ] **project-name**: description of what they need to do`

### 4. Shared strategy files
- [ ] If infrastructure, deployment, or shared state changed → update `~/cfg-agent-fleet/cross-project/infrastructure-strategy.md`
- [ ] If visibility/outreach state changed → update `~/cfg-agent-fleet/cross-project/fmt-visibility-strategy.md`
- [ ] Only update strategy files you actually touched this session — don't speculatively refresh them

### 5. Machine knowledge
- [ ] If machine-specific state changed (tooling installed, patches applied, auth rotated) → update `~/.claude/machines/<machine>.md`
- [ ] If new operational knowledge discovered (tool bugs, workarounds) → update or create `~/.claude/knowledge/<tool>.md`

### 6. Commit and push
- [ ] `git add` changed files, commit with descriptive message
- [ ] `git push` (or rely on SessionEnd auto-sync hook if configured)
- [ ] If publication files were modified, follow the extended checklist in `publication-workflow.md` Section 6

### 7. Verify sync (if applicable)
- [ ] Run `bash ~/cfg-agent-fleet/sync.sh collect` to verify it exits cleanly
- [ ] If it fails, fix the issue or clear `.sync-failed` marker with explanation

**The user must be able to open consistent, up-to-date files after the session ends.** Stale context, missing inbox tasks, or outdated strategy files are unacceptable.

**Note:** Drive unmount is handled by the `afleet` launcher post-session reminder (not the shutdown checklist — Claude Code lacks sudo for unmount).
