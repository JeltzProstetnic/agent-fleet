# Session Shutdown Checklist — MANDATORY

**Before every session end, run through this checklist in order.**
**If shutdown was already completed this session, it is VOID — re-run the full checklist from step 0.**

### 0. Clean stale permissions
- [ ] Run `bash ~/agent-fleet/setup/scripts/clean-permissions.sh` — removes "Always allow" permission blocks from project settings.local.json files that shadow global permissions and cause prompt storms during shutdown

### 1. Session context and work products
- [ ] **Persist work products first.** If this session produced significant artifacts (maps, analysis results, generated data, exploration outputs, plans) that exist only in conversation context, write them to files NOW — before they're lost with the session. Recovery instructions that say "reference the X from this session" are worthless if X was never saved. Common culprits: subagent outputs, exploration results, dependency maps, architecture diagrams.
- [ ] **Clean completed pending files.** Check all `docs/pending-*.md` — if the work a file describes was completed this session, delete it. If a pending file is also a handoff target (`next-session-task.md` → `file:`), clear the handoff too (`task: false`). Stale pending files cause the next session to re-propose finished work.
- [ ] Update `session-context.md` with final state, completed work, and recovery instructions
- [ ] Update this project's row in `~/agent-fleet/cross-project/dashboard-cache.md` **with `bash ~/agent-fleet/setup/scripts/dashboard-row.sh <project> --tasks "…" --size "…" --deadline "…"` — never by editing the file** (`Edit`/`Write` of the whole file reverted another project's freshly written row once; the script rewrites only your row, under a lock). Task counts (grep backlog), disk size (`du -sh`); pass only the fields that changed (`--p1names`, `--lastdone` also exist). **Deadline column is a 1-2 line current-state snapshot — each flag REPLACES the entire field content, never append. Session history belongs in `docs/session-log.md`, not the dashboard.**

### 2. Session rotation
- [ ] Run `bash ~/agent-fleet/setup/scripts/rotate-session.sh` to archive session to history/log and reset template
- [ ] If significant decisions were made (check: does session-context `## Key Decisions` have 2+ items?), promote them to `docs/decisions.md` before commit
<!-- NEEDS TOKEN EFFICIENCY CHECK: decisions.md promotion reminder added 2026-03-05. Could be a hook that greps session-context.md. -->

### 3. Cross-project inbox
- [ ] **Mark completed inbox items `[x]`.** Check `~/agent-fleet/cross-project/inbox.md` for any `[ ]` items targeting THIS project that were completed this session. Mark them `[x]`. This is mandatory — stale unchecked items cause the next session to re-propose already-finished work. **Infrastructure/connectivity tasks require end-to-end verification** (e.g., `ssh ... echo test`, `curl -sI`, `deploy && verify`) — script fixes + backlog tracking alone do NOT count as completion.
- [ ] If this session's work affects other projects, drop tasks in `~/agent-fleet/cross-project/inbox.md`
- [ ] Each entry targets ONE project — never broadcast
- [ ] Format: `- [ ] **project-name**: description of what they need to do`

### 4. Shared strategy files
- [ ] If infrastructure, deployment, or shared state changed → update `~/agent-fleet/cross-project/infrastructure-strategy.md`
- [ ] If visibility/outreach state changed → update `~/agent-fleet/cross-project/fmt-visibility-strategy.md`
- [ ] Only update strategy files you actually touched this session — don't speculatively refresh them

### 5. Machine knowledge
- [ ] If machine-specific state changed (tooling installed, patches applied, auth rotated) → update `~/.claude/machines/<machine>.md`
- [ ] If new operational knowledge discovered (tool bugs, workarounds) → update or create `~/.claude/knowledge/<tool>.md`

### 5.5. Postmortem pattern extraction
- [ ] If this session identified reusable patterns from a project (e.g., "project X solved problem Y this way"):
  - Check if the pattern is already in the type template (`setup/projects/_templates/<type>/`)
  - If not: create an inbox task for agent-fleet: `- [ ] **agent-fleet**: Extract pattern from <project> — <description>. Type template: <type>.`
  - If this session IS a cfg session and the pattern is available: add directly to the template

### 6. Commit and push
- [ ] **agent-fleet only:** Run `bash setup/scripts/anti-lockout-check.sh` — verifies hook syntax, JSON validity, safe-run routing, symlink integrity
- [ ] `git add` changed files, commit with descriptive message
- [ ] `git push` — always push explicitly, SessionEnd hook is a backup safety net only
- [ ] If publication files were modified, follow the extended checklist in `publication-workflow.md` Section 6

### 7. Verify sync (if applicable)
- [ ] Run `bash ~/agent-fleet/sync.sh deploy` to verify it exits cleanly (v1.0: deploy-only, no collect)
- [ ] If it fails, fix the issue or clear `.sync-failed` marker with explanation
- [ ] Deploy also runs automatically via SessionEnd hook — this is a manual verification step

### 8. Handover — MANDATORY, every session, no exceptions
- [ ] Write `docs/pending-<topic>.md` that lets the next session resume this session's work without re-deriving it: what was being done, where it stopped, the next concrete action, and every open question or decision the user must read. Mark it `<!-- Action: await-user-decision -->` and point `## Next Session Task` at it.
- [ ] Carry every work item the user explicitly ordered this session and did not receive into that same file, in his words — an explicit order is never dropped for being unfinished, out of scope, or superseded by other work.
- [ ] A session with nothing in flight still writes the handover and says so in one line; `backlog:` may be `none` only in that case.
- [ ] Write every open decision in the handover as a question with 2–4 concrete options (recommended first), ready to be asked verbatim with AskUserQuestion at session start.
- [ ] Every credential the next session needs is named by location (vault key, file path), never by value — the handover is pushed with the repo.

### 9. Closing message
- [ ] A shutdown response contains no questions, decisions, or approval requests anywhere — this overrides "User decisions as selectable options", and everything the user must answer goes in the handover file instead.
- [ ] End the response with the completion announcement and nothing after it — no questions, no approval requests, no "let me know", because any answer voids the shutdown you just ran.

**The user must be able to open consistent, up-to-date files after the session ends.** Stale context, missing inbox tasks, or outdated strategy files are unacceptable.

**Note:** Drive unmount is handled by the `afleet` launcher post-session reminder (not the shutdown checklist — Claude Code lacks sudo for unmount).
