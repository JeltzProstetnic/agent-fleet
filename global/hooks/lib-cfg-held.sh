#!/usr/bin/env bash
# lib-cfg-held.sh — is the config repo held by a DIFFERENT live session?
# (CFG-666 / CFG-665 / CFG-965). Sourced by config-auto-sync.sh (SessionEnd).
#
# Reads from the caller: CONFIG_REPO, ORIGINAL_DIR, _shutdown_progress.
# Sets: _CFG_HELD_BY_OTHER (0/1) and _CFG_HELD_RECORDED (1 once an "unknown"
# record was written to the drift log). Every phase of the hook that writes to,
# deletes from, deploys or publishes the config repo's working tree consults
# _CFG_HELD_BY_OTHER: a held repo's tree is its holder's in-progress work, and
# the holder does all of that at its own shutdown.
#
# check_lock (setup/scripts/session-lock.sh) answers 0 free, 1 ours, 2 another
# live session on this machine, 3 another machine (unverifiable), 4 cannot
# determine (no Claude Code process visible to the scan). Here 0/1 ⇒ not held,
# 2/3 ⇒ held, and EVERYTHING ELSE ⇒ held and recorded as unknown: 4, the 5
# below, and whatever a broken function returns (127 for a missing one).
#
# SF-1 (CFG-965): session-lock.sh is sourced from the working tree it protects.
# A cfg session half-way through editing it — a syntax error before check_lock,
# a rename — left check_lock undefined in the hook, and the probe answered "not
# held" on `command -v check_lock || return 0`: the one session the guard exists
# for disarmed it. _cfg_held_check_lock takes HEAD's copy of the library instead
# (`git show`), evaluated in a subshell so a broken copy cannot poison the hook,
# and answers 5 when neither copy yields a check_lock. With a lock file present
# that is "held, unknown"; without one there is nothing to be closed about and
# no process scan possible, so it is "not held" — the pre-SF-1 answer, now only
# for the lock-less case.
#
# Expected skips are AUDIT lines under $HOME/.claude/logs (_cfg_defer_audit),
# never .sync-warnings.log: checks/04-auto-fix.sh surfaces every line of that
# file at the next SessionStart of ANY project as "propagation drift … fix with
# sync.sh deploy". The unknown state IS for the next SessionStart, so it goes
# to the drift log (_cfg_held_record_unknown), once.

_CFG_HELD_BY_OTHER=0
_CFG_HELD_RECORDED=0
_CFG_HELD_UNKNOWN_RECORD=""
_CFG_DRIFT_LOG_RESET_PENDING=0
_CFG_DEFER_AUDIT_LOG="$HOME/.claude/logs/template-push-deferred.log"

_cfg_held_notice() {
    _shutdown_progress "Config repo is held by another live session — its context and work are left to it."
}

# <TAG> <text> — one audit line for an expected skip.
_cfg_defer_audit() {
    mkdir -p "$(dirname "$_CFG_DEFER_AUDIT_LOG")" 2>/dev/null
    printf '%s %s: %s (shutdown of %s)\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" "$1" "$2" \
        "$(basename "$ORIGINAL_DIR")" >> "$_CFG_DEFER_AUDIT_LOG" 2>/dev/null || true
}

# <reason> — held, and the unknown state recorded for the next SessionStart, once.
# The record reaches the drift log at once — unless the caller has announced
# (_CFG_DRIFT_LOG_RESET_PENDING=1) that it will still REWRITE that log from
# scratch (config-auto-sync.sh's Phase 0.7 does): then it is stashed and the
# caller appends it afterwards with _cfg_held_flush_record.
_cfg_held_record_unknown() {
    _CFG_HELD_BY_OTHER=1
    [[ "$_CFG_HELD_RECORDED" -eq 1 ]] && return 0
    _CFG_HELD_RECORDED=1
    _shutdown_progress "Config repo lock state unknown ($1) — treated as held; its context and work are left alone."
    _CFG_HELD_UNKNOWN_RECORD="$(date -u +'%Y-%m-%d %H:%M:%S UTC') config repo lock state unknown ($1) — treated as held: rotation, deploy, propagation and commit skipped, lock left in place"
    [[ "$_CFG_DRIFT_LOG_RESET_PENDING" -eq 1 ]] || _cfg_held_flush_record
}
_cfg_held_flush_record() {
    _CFG_DRIFT_LOG_RESET_PENDING=0
    [[ -n "$_CFG_HELD_UNKNOWN_RECORD" ]] || return 0
    echo "$_CFG_HELD_UNKNOWN_RECORD" >> "$CONFIG_REPO/.sync-warnings.log" 2>/dev/null || true
    _CFG_HELD_UNKNOWN_RECORD=""
}

# <repo> — check_lock's verdict from HEAD's copy of session-lock.sh whenever that
# copy is obtainable (`git show`), from the live library only when it is not;
# 5 = no usable check_lock. HEAD FIRST (SF-1 residual, reviewer 2026-11-11): a
# live copy whose check_lock still parses while a helper it calls is mid-rename
# gets 127 from that helper, reads it as "no live session", and its dead-pid
# branch deletes the lock and answers "free" — asking the live copy first is
# asking the editor's half-finished file for a verdict about the editor. An
# obtainable but broken HEAD copy is 5, never a fallback to the live one. eval,
# not source: eval parses the whole copy first, so a syntax error anywhere
# defines nothing (5), where source would leave a check_lock whose later
# helpers are missing.
_cfg_held_check_lock() {
    local repo="$1" rc=0 lib=""
    # env -u: an inherited GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE would point git
    # at another repo; `-C <repo>` must mean THIS repo's HEAD.
    lib="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$repo" show HEAD:setup/scripts/session-lock.sh 2>/dev/null)" || lib=""
    if [[ -n "$lib" ]]; then
        ( eval "$lib" >/dev/null 2>&1 || exit 5
          command -v check_lock >/dev/null 2>&1 || exit 5
          # 6: a lock is on disk that HEAD's library cannot read — empty,
          # corrupt, or a newer format. Its check_lock would call that
          # "corrupt" and, with no live CC visible, DELETE it and answer "free"
          # (session-lock.sh's corrupt branch); and its _read_lock (python/jq)
          # accepts ANY JSON, leaving _LOCK_PID empty for a pid under a name it
          # does not know — which check_lock then reads as a dead pid. So
          # "readable" is: _read_lock succeeds AND machine is set AND pid is
          # numeric. A lock the library cannot read is held, recorded, kept.
          if [[ -f "$repo/.claude/.session-lock" ]]; then
              { _read_lock "$repo/.claude/.session-lock" >/dev/null 2>&1 \
                && [[ -n "$_LOCK_MACHINE" && "$_LOCK_PID" =~ ^[0-9]+$ ]]; } || exit 6
          fi
          check_lock "$repo" >/dev/null 2>&1 ) || rc=$?
        return "$rc"
    fi
    command -v check_lock >/dev/null 2>&1 || return 5
    check_lock "$repo" >/dev/null 2>&1 || rc=$?
    return "$rc"
}

# The verdict. Only ever turns "not held" into "held"; the hook does not probe
# a repo it already holds as held, so the unknown record is written at most once.
_cfg_held_probe() {
    if [[ "$ORIGINAL_DIR" == "$CONFIG_REPO" ]]; then
        # The project IS the config repo: a genuine leader released its own
        # lock in Phase -1, so a lock still present — that check_lock calls
        # foreign — is the answer. (Phase 1's guard asks the same; Phase 3 adds
        # its verdict once it exists.)
        [[ -f "$CONFIG_REPO/.claude/.session-lock" ]] || return 0
    fi
    local rc=0
    _cfg_held_check_lock "$CONFIG_REPO" || rc=$?
    case "$rc" in
        0|1) ;;
        2|3) _CFG_HELD_BY_OTHER=1; _cfg_held_notice ;;
        4)   _cfg_held_record_unknown "check_lock=4: no Claude Code process visible to the lock check" ;;
        6)   _cfg_held_record_unknown "check_lock=6: a lock is present that HEAD's session-lock.sh cannot read (empty, corrupt, or a newer format) — left in place; if no cfg session is live, clear it with session-lock.sh force_release" ;;
        5)   [[ -f "$CONFIG_REPO/.claude/.session-lock" ]] \
                 && _cfg_held_record_unknown "check_lock unavailable: session-lock.sh yields no check_lock in the working tree nor at HEAD" ;;
        *)   _cfg_held_record_unknown "check_lock=$rc: a result this hook cannot classify" ;;
    esac
    return 0
}
