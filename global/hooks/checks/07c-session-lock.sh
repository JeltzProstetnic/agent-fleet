#!/usr/bin/env bash
# Check group 7c: Session lock and session role (split from 07b-platform-env.sh, CFG-721)
# Checks: 7c.1
# Shared vars used: CONFIG_REPO, WARNINGS, PWD

# Check 7c.1 (formerly 7b.4): Session lock — detect if another session holds this project
_SESSION_LOCK_LIB="$CONFIG_REPO/setup/scripts/session-lock.sh"
if [ -f "$_SESSION_LOCK_LIB" ]; then
    source "$_SESSION_LOCK_LIB"
    check_lock "$PWD" 2>/dev/null
    _lock_rc=$?
    # check_lock's verdict is final. It already recognises the leader itself: by
    # the lock's ccSessionId (CC_SESSION_ID here, CLAUDE_CODE_SESSION_ID in a
    # tool subprocess — CFG-454, also on a dead recorded pid), by launcher
    # ancestry for the af path (CFG-672), and by AFLEET_SESSION_ID only when the
    # CC matcher is degraded (a tmux-launched CC inherits that id from the tmux
    # server, and ancestry cannot see it). Every id match is gated on "not a
    # nested CC", because a nested CC INHERITS the leader's env.
    # An ungated re-comparison here (2026-03 → 2026-09)
    # flipped rc 2 → 1 for exactly that nested CC, marked it `leader`, and its
    # SessionEnd then rotated the leader's live session-context.md (CFG-666).

    case $_lock_rc in
        2)
            _read_lock "$PWD/.claude/.session-lock" 2>/dev/null
            # CFG-740: say WHAT holds the project, not just that it is held. The
            # verdict stays check_lock's; this only names the shape so the next
            # agent does not file it as a false follower (life WSL 2026-10-06).
            #  - Holder pid is an ANCESTOR of this session's own CC: this session
            #    was started FROM the leader — a nested CC, or a daemon-hosted
            #    background session (/background, /fork, the agents view). The
            #    leader is alive and will run its own SessionEnd, so this one is
            #    a follower by design, not the victim of a stale lock.
            #  - No lock file at all: a live CC is cwd'd here without one — a
            #    direct launch, or a background job that outlived its leader.
            _lock_shape=""
            _own_cc="$(_cc_self_pid)"
            if [ -n "$_own_cc" ] && [ -n "$_LOCK_PID" ] && _pid_is_descendant_of "$_own_cc" "$_LOCK_PID"; then
                _lock_shape=" NESTED: the holder is an ancestor of this session's own Claude Code process — this session was started from the leader (nested CC or daemon-hosted background session), follower by design, not a stale lock (CFG-740)."
            fi
            if [ -n "$_LOCK_PID" ]; then
                _lock_desc="Project locked by PID $_LOCK_PID (session $_LOCK_SESSION) on this machine.${_lock_shape}"
            else
                _lock_desc="A live Claude Code session is working in this project with no readable lock file (a direct launch, or a background session that outlived its leader — 'claude agents' lists those)."
            fi
            WARNINGS="${WARNINGS:+$WARNINGS | }SESSION_LOCKED: ${_lock_desc} FOLLOWER — load knowledge/follower-mode.md and follow it."
            # CFG-452 Phase 2: another live session holds this project → follower.
            # Persist the role so SessionEnd skips shared-state mutation.
            write_role "$PWD" follower "${CC_SESSION_ID:-}" "${AFLEET_SESSION_ID:-}" 2>/dev/null || true
            ;;
        3)
            _read_lock "$PWD/.claude/.session-lock" 2>/dev/null
            WARNINGS="${WARNINGS:+$WARNINGS | }SESSION_LOCKED_REMOTE: Project locked by $_LOCK_MACHINE (session $_LOCK_SESSION). FOLLOWER — load knowledge/follower-mode.md and follow it."
            # CFG-452 Phase 2: locked by another machine → follower (remote).
            write_role "$PWD" follower "${CC_SESSION_ID:-}" "${AFLEET_SESSION_ID:-}" 2>/dev/null || true
            ;;
        0)
            acquire_lock "$PWD" "${AFLEET_SESSION_ID:-}" 2>/dev/null
            # CFG-452: bind the lock to this CC session id (immune to an
            # inherited AFLEET_SESSION_ID). No-op if CC_SESSION_ID is empty.
            stamp_cc_session "$PWD" "${CC_SESSION_ID:-}" 2>/dev/null || true
            # CFG-452 Phase 2: this session acquired the lock → leader.
            write_role "$PWD" leader "${CC_SESSION_ID:-}" "${AFLEET_SESSION_ID:-}" 2>/dev/null || true
            ;;
        1)
            # CFG-452: own lock (afleet re-detect) — bind it to this CC session too.
            stamp_cc_session "$PWD" "${CC_SESSION_ID:-}" 2>/dev/null || true
            # CFG-452 Phase 2: this session already owns the lock → leader.
            write_role "$PWD" leader "${CC_SESSION_ID:-}" "${AFLEET_SESSION_ID:-}" 2>/dev/null || true
            ;;
        *)
            # 4 = cannot determine (CFG-673 / GH#9), and any rc this module does
            # not know. The lock check saw no Claude Code process at all, not
            # even this session's own, so it cannot tell a free project from
            # one held by a session it cannot see. Fail closed: no acquire, the
            # lock (if any) stays, and this session is a follower.
            WARNINGS="${WARNINGS:+$WARNINGS | }SESSION_LOCK_UNKNOWN: Cannot tell whether another session holds this project — the lock check sees no Claude Code process, not even this one (check_lock=$_lock_rc). Treated as held: FOLLOWER — load knowledge/follower-mode.md and follow it. If the user confirms no other session is running here, force_release + acquire_lock takes the lead."
            write_role "$PWD" follower "${CC_SESSION_ID:-}" "${AFLEET_SESSION_ID:-}" 2>/dev/null || true
            ;;
    esac
    # CFG-592: rc 0/1 = this session leads. When the check could not identify
    # this session's OWN Claude Code process while other CCs are visible, its
    # liveness scan failed open without looking (deliberate — a solo session must
    # never self-block; the blind case is rc 4 above), so the lead rests on an
    # unproven "no other session here". Owner decision 2026-09-28: keep granting,
    # say so loudly.
    if [ "$_lock_rc" -le 1 ] && lock_self_unknown; then
        WARNINGS="${WARNINGS:+$WARNINGS | }SESSION_LOCK_SELF_UNKNOWN: The lock check could not identify this session's own Claude Code process — no ancestor of this hook matches the CC matcher (_CC_PROC_RE may not match this install's own CC, cf. CFG-590/GH#7; compare 'pgrep -af claude' against it) — while other Claude Code process(es) ARE visible. Its liveness scan therefore cannot tell this session from a rival and failed open without looking (deliberate: a solo session must never block itself), so the 'no other session here' behind this lead (check_lock=$_lock_rc) is UNPROVEN: a second session already running in this project would NOT have been detected, now or at shutdown. Proceeding as LEADER — ask the user whether another session is open on this project before writing shared state, and report the matcher gap to the fleet config repo."
    fi
fi
