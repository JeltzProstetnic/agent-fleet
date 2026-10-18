<!-- updates: (none currently) -->
<!-- consumed-by: global/hooks/checks/07c-session-lock.sh (SESSION_LOCKED / SESSION_LOCKED_REMOTE / SESSION_LOCK_UNKNOWN point here), global/hooks/checks/06b-lock-knowledge.sh (SESSION_LOCKED_REMOTE), global/CLAUDE.md (conditional loading trigger) -->
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

## Nested and Background Sessions (CFG-740)

`SESSION_LOCKED … NESTED` means the lock holder is an **ancestor** of this session's own Claude Code process: this session was started *from* the leader — a nested `claude` run from a Bash tool, or a daemon-hosted background session created by `/background` (`/bg`), `/fork`, or the agents view (`←` at an empty prompt). Measured ancestry (life WSL 2026-10-06): `afleet.sh → script → claude.exe (leader) → claude daemon run → claude --bg-pty-host → claude --session-id <this>`.

Follower **by design**, not a stale lock: the leader is alive, owns the lock, and runs its own SessionEnd (rotation, lock release) when it exits. A `force_release` here hands the lock to a second leader while the first is still alive — the CFG-666 clobber. Work in the worktree, or stop this job and continue in the leader.

Background-session facts (Claude Code 2.1.280, read from the binary and the daemon's own records):
- `/exit` inside an attached background session only **detaches**; the job, its MCP servers and the transient `claude daemon run` keep running and outlive the leader (reparented to init).
- End a job with `/stop` inside it, or `claude stop <id>` / `claude agents` (ctrl+x twice) from any shell; `claude attach <id>` re-opens it.
- While a job stays cwd'd in a project, every later session there is a follower too (`SESSION_LOCKED` with no lock file) until the job is stopped.

## CLAUDE.md Edits Deferred (CFG-384)

Never edit any `CLAUDE.md` (global or project) while follower mode is active — concurrent worktrees merge-clobber rule changes silently, and rule edits need the focused Meta-Rules consent channel.

**Instead:** draft the full proposed diff + rationale into `docs/pending-claude-md-<slug>.md` with `Action: act`, tell the user it will apply on next solo session, and stop.
