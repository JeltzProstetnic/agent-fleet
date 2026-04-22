<!-- updates: (none currently) -->
<!-- consumed-by: global/hooks/checks/07-environment.sh (Check 31 sends override request), global/CLAUDE.md (conditional loading trigger) -->
# Follower Mode

Another session holds the project lock. Run `EnterWorktree` NOW — before any file writes.

After entering the worktree, **resume the normal startup protocol** (session bookkeeping, session-context.md population, pending files — all of it). The worktree IS your workspace; startup applies there.

**Path warning:** In a worktree, absolute paths to the main repo (e.g., `/home/user/project/file`) bypass the worktree and edit main directly. Use **relative paths** or the **worktree's absolute path** (shown by `pwd`) for all file operations.

## Remote Lock Override (CFG-101a)

When the lock is held by **another machine** (`SESSION_LOCKED_REMOTE`), the SessionStart hook automatically sends a Telegram notification to the user requesting override approval.

**Flow:**
1. Check 31 detects remote lock → sets `SESSION_LOCKED_REMOTE` warning
2. Hook sends Telegram permission request: "Override lock held by [machine]?"
3. User can approve via Telegram (`/approve`) or deny
4. If approved: user tells this session to force-release and re-acquire

**What to do in this session:**
- If the user says "override" or "take the lock": run `force_release` on the lock file, then `acquire_lock` for this session
- If the user doesn't override: stay in worktree mode (read-only for shared state)
- If AFD is running: use `afd_lock_release` + `afd_lock_acquire` instead of local file ops

**Stale remote locks:** If a lock is from a crashed session (hours old, no heartbeat), the user should override. Don't auto-override — always confirm with the user first.

## CLAUDE.md Edits Deferred (CFG-384)

Never edit any `CLAUDE.md` (global or project) while follower mode is active — concurrent worktrees merge-clobber rule changes silently, and rule edits need the focused Meta-Rules consent channel.

**Instead:** draft the full proposed diff + rationale into `docs/pending-claude-md-<slug>.md` with `Action: act`, tell the user it will apply on next solo session, and stop.
