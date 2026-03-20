# Follower Mode

Another session holds the project lock. Run `EnterWorktree` NOW — before any file writes.

After entering the worktree, **resume the normal startup protocol** (session bookkeeping, session-context.md population, pending files — all of it). The worktree IS your workspace; startup applies there.

**Path warning:** In a worktree, absolute paths to the main repo (e.g., `/home/user/project/file`) bypass the worktree and edit main directly. Use **relative paths** or the **worktree's absolute path** (shown by `pwd`) for all file operations.

## Remote Lock Override

When the lock is held by **another machine** (`SESSION_LOCKED_REMOTE`), the session may need to override.

**What to do in this session:**
- If the user says "override" or "take the lock": run `force_release` on the lock file, then `acquire_lock` for this session
- If the user doesn't override: stay in worktree mode (read-only for shared state)
- If AFD is running: use `afd_lock_release` + `afd_lock_acquire` instead of local file ops

**Stale remote locks:** If a lock is from a crashed session (hours old, no heartbeat), the user should override. Don't auto-override — always confirm with the user first.
