#!/usr/bin/env bash
# afleet-cfg-held.sh — is the config repo held by another live session, asked
# from OUTSIDE any Claude Code session: the launcher before it pulls or deploys
# the config repo, and the hand-run recovery commands (CFG-977).
#
# Why: `sync.sh deploy` copies the config repo's WORKING TREE to ~/.claude. While
# another live session holds the repo, that tree is its in-progress work — on
# 2026-11-12 08:27 another project's launch deployed a live cfg session's
# uncommitted hook edits. CFG-965 closed the shutdown path (config-auto-sync.sh;
# Q-965-DEPLOY: skip, no HEAD-only deploy). This is the same verdict for launches.
#
# Two ways in. The launcher and afleet-recover.sh RUN it (CLI below), as its own
# process: a broken copy — even one that exits at its top — cannot take its caller
# down, and they fail closed on a lock file when it gives no usable answer.
# Sourcing it defines functions and result variables and runs nothing.
#
# The verdict is lib-cfg-held.sh's _cfg_held_check_lock (HEAD's session-lock.sh
# first; 5 = no usable check_lock; 6 = a lock HEAD's library cannot read), loaded
# from a copy that cannot be mid-edit: HEAD's lib-cfg-held.sh, else the DEPLOYED
# ~/.claude/hooks copy — never the working tree, which is the holder's.
# No usable library and a lock file present ⇒ held (fail closed).
#
# Asked as a NON-CC caller: _CC_SELF_PID is the caller's own pid, as afleet passes
# its pid to acquire_lock, so check_lock's liveness scan RUNS (with an empty self it
# fails open). The session ids a terminal can inherit (CC_SESSION_ID,
# CLAUDE_CODE_SESSION_ID, CLAUDE_SESSION_ID, AFLEET_SESSION_ID) are dropped: they
# name some other session, never this caller.
#
# READ-ONLY: check_lock deletes a lock it judges stale; here `rm` does nothing. A
# launch never removes a lock, so a process table this caller cannot fully see
# (a PID namespace) cannot turn a live holder's lock into "deleted".
#
# Map: 0 ⇒ not held. 2 a live session here, 3 a session on another machine, 1 a
# lock bound to the caller's own process tree (a launcher is never the holder
# yet), 4/6/anything else unknown ⇒ held. 5 and "no library" ⇒ held only with a
# lock file. A crashed holder's lock (pid dead, no live CC in the repo) answers 0,
# so it never suppresses a deploy. Every held reason but a live holder (2) comes
# with a runnable remedy (AFLEET_CFG_HELD_FIX).

AFLEET_CFG_HELD_WHY=""
AFLEET_CFG_HELD_FIX=""
AFLEET_LAUNCH_DEPLOY_NOTE=""

# <repo> — print a lib-cfg-held.sh that parses and defines _cfg_held_check_lock:
# HEAD's, else the deployed copy. rc 1 when neither does.
_afleet_cfg_held_lib() {
    local repo="$1" src text
    for src in head deployed; do
        if [[ "$src" == head ]]; then
            text="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
                git -C "$repo" show HEAD:global/hooks/lib-cfg-held.sh 2>/dev/null)" || text=""
        else
            text="$(cat "$HOME/.claude/hooks/lib-cfg-held.sh" 2>/dev/null)" || text=""
        fi
        [[ -n "$text" ]] || continue
        bash -n <<< "$text" 2>/dev/null || continue
        grep -q '^_cfg_held_check_lock()' <<< "$text" || continue
        printf '%s\n' "$text"
        return 0
    done
    return 1
}

# <repo> — _cfg_held_check_lock's raw result for a non-CC, read-only caller;
# 100 = no usable library. Evaluated in a subshell: nothing it defines or sets
# reaches the caller.
_afleet_cfg_lock_rc() {
    local repo="$1" lib rc=0 tree_lock="$1/setup/scripts/session-lock.sh"
    lib="$(_afleet_cfg_held_lib "$repo")" || return 100
    ( set +eu
      unset CC_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID AFLEET_SESSION_ID
      _CC_SELF_PID="$$"
      rm() { :; }
      eval "$lib" >/dev/null 2>&1
      declare -F _cfg_held_check_lock >/dev/null || exit 100
      # No HEAD at all (a template-only deployment): the working tree's
      # session-lock.sh is the only copy, and _cfg_held_check_lock's live fallback.
      if ! env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
              git -C "$repo" rev-parse -q --verify HEAD >/dev/null 2>&1 \
         && bash -n "$tree_lock" 2>/dev/null; then
          source "$tree_lock" >/dev/null 2>&1
      fi
      _cfg_held_check_lock "$repo" ) || rc=$?
    return "$rc"
}

# <repo> <pid|machine> — that field of the lock file, best effort.
_afleet_cfg_lock_field() {
    sed -n "s/.*\"$2\" *: *\"\{0,1\}\([^\",}]*\).*/\1/p" "$1/.claude/.session-lock" 2>/dev/null | head -1
    return 0
}

# <repo> — rc 0 when held (or not ruled out), 1 when not held.
# AFLEET_CFG_HELD_WHY completes "<repo> is …"; AFLEET_CFG_HELD_FIX is the remedy.
afleet_cfg_held() {
    local repo="$1" rc=0 pid machine
    AFLEET_CFG_HELD_WHY="" AFLEET_CFG_HELD_FIX=""
    _afleet_cfg_lock_rc "$repo" || rc=$?
    pid="$(_afleet_cfg_lock_field "$repo" pid)"
    machine="$(_afleet_cfg_lock_field "$repo" machine)"
    case "$rc" in
        0)  return 1 ;;
        2)  if [[ -n "$pid" ]]; then
                AFLEET_CFG_HELD_WHY="held by a live session on this machine (lock pid $pid)"
            else
                AFLEET_CFG_HELD_WHY="in use by a live Claude Code session (no lock file)"
            fi
            return 0 ;;
        3)  AFLEET_CFG_HELD_WHY="held by a session on ${machine:-another machine}" ;;
        1)  AFLEET_CFG_HELD_WHY="held by a session in this launcher's own process tree${pid:+ (lock pid $pid)}" ;;
        5|100)
            [[ -f "$repo/.claude/.session-lock" ]] || return 1
            AFLEET_CFG_HELD_WHY="possibly held (lock state unknown: no usable lock library, and a session lock is present)" ;;
        *)  AFLEET_CFG_HELD_WHY="possibly held (lock state unknown, check_lock=$rc)" ;;
    esac
    AFLEET_CFG_HELD_FIX="If no session is live there: rm -f $repo/.claude/.session-lock"
    return 0
}

# <tag> <text> <project> — one audit line in the CFG-965 audit log for expected skips.
_afleet_cfg_audit() {
    local log="$HOME/.claude/logs/template-push-deferred.log"
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    printf '%s %s: %s (launch of %s)\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" "$1" "$2" "$3" \
        >> "$log" 2>/dev/null || true
}

# <repo> <project> — the launch-time deploy is skipped (afleet_cfg_held said
# held): one audit line, and the console note the launcher prints once its
# spinner is gone (AFLEET_LAUNCH_DEPLOY_NOTE). AFLEET_CFG_PULL_SKIPPED=1 when
# the pre-picker pull of the repo was skipped too.
afleet_cfg_deploy_deferred() {
    local name what="deploying"
    name="$(basename "$1")"
    [[ -n "${AFLEET_CFG_PULL_SKIPPED:-}" ]] && what="pulling or deploying"
    _afleet_cfg_audit LAUNCH_DEPLOY_DEFERRED \
        "$name is $AFLEET_CFG_HELD_WHY — sync.sh deploy of its working tree skipped${AFLEET_CFG_PULL_SKIPPED:+, and its pre-launch pull}; the holder deploys at its own shutdown" "$2"
    AFLEET_LAUNCH_DEPLOY_NOTE="  ⚠ $name is $AFLEET_CFG_HELD_WHY — not $what its working tree; the holder deploys at its shutdown.${AFLEET_CFG_HELD_FIX:+ $AFLEET_CFG_HELD_FIX}"
    return 0
}

# ── CLI ───────────────────────────────────────────────────────────────────────
#   held <repo>                                   → "held<TAB>why<TAB>fix" or "free"
#   defer <repo> <project> <why> [fix] [pulled]   → audit line written, note printed
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        held)
            if afleet_cfg_held "${2:-}"; then
                printf 'held\t%s\t%s\n' "$AFLEET_CFG_HELD_WHY" "$AFLEET_CFG_HELD_FIX"
            else
                echo free
            fi ;;
        defer)
            AFLEET_CFG_HELD_WHY="${4:-}" AFLEET_CFG_HELD_FIX="${5:-}" AFLEET_CFG_PULL_SKIPPED="${6:-}"
            afleet_cfg_deploy_deferred "${2:-}" "${3:-}"
            printf '%s\n' "$AFLEET_LAUNCH_DEPLOY_NOTE" ;;
        *)  echo "usage: afleet-cfg-held.sh held <repo> | defer <repo> <project> <why> [fix] [pull-skipped]" >&2
            exit 2 ;;
    esac
fi
