#!/usr/bin/env bash
# shutdown-follow.sh — the watcher behind global/hooks/shutdown-follow.sh (CFG-1043 / CFG-1044): a session
# typing its own follow-up command after a `cls` / `end` shutdown. Launched detached by the hook when a
# real prompt holds `cls` or `end` as a word; it waits until the session's TRANSCRIPT, after the arming
# offset, shows a turn that ENDED on a "Shutdown complete" line (rs_shutdown_reported, CFG-1001) and the
# session's record is neither busy nor waiting (a dialog), then types — as remote-session.sh types a
# command line: the input line cleared, the text, a gap, Enter alone, the dialog guard read before each —
#   "Next: /exit"  → /exit, and waits for the pid to go (CC's background-work selector answered, rs_wait_gone)
#   "Next: /clear" → /clear, waits for the fresh session (rs_wait_cleared), then submits `startup` ONLY
#                    while caretaking is active (~/.afd-care, lib-care.sh's reader: first word `active`)
#   no hint        → the arming keyword decides (cls → /clear, end → /exit); both armed → nothing, logged.
# Cancellation is the state file $DIR/<pid> (the hook deletes or rewrites it on every later real prompt):
# its token is re-read every poll and, together with the record's status and session id (sf_may_type), right
# before the clearing keys, before the text and before the Enter — another token or no file (cancelled), a
# record gone busy (the user's queued prompt ran once the shutdown turn ended) or carrying another session id
# (the user typed /clear by hand: a built-in command fires no prompt hook, so nothing else tells us) → stand
# down, exit 0, log only; a text already in the box is cleared again, as a driver's type_or_die does. A completed shutdown is
# judged by rs_shutdown_turn (remote-session-follow-lib.sh): ANY turn after the arming offset that ended on
# the completion line, so a synthetic turn right after it cannot hide it; its own "Next:" hint is used.
# Failures AFTER a shutdown was seen (a dialog stayed up, /clear or /exit did not take, startup not
# confirmed) are logged and, while AFK is on (~/.afd-afk) and the AFD CLI exists, sent as ONE Telegram line
# via `afd notify`; at the console the session's own "Next: /clear" / "Next: /exit" line stays the human
# fallback. A timeout with no shutdown ever seen — the normal fate of a false arm — is log-only, and so is a
# machine where this watcher has no way to type at all (no tmux pane, no Konsole tab, not WSL, or a tty it
# cannot read — a plain terminal, macOS): that is probed once at the start, before anything is waited for.
# `startup` after /clear needs an active care shift; without the care machinery (lib-care.sh) the care
# line's first word is read directly, and a fleet without the file never submits it.
#
# Q-TYPE-SELF: a session typing into ITSELF is exempt from CFG-1028's typing gate — rs_safety_check is
# called here with caller == pid and allow_self=1, and the gate (rs_typing_allowed, remote-session-gate-lib.sh)
# runs only for another target: this script and a driver's --self depend on it.
#
# Usage: shutdown-follow.sh --pid <claude pid> --token <token> [--state-dir D] [--wait S] [--clear-wait S]
#        [--exit-wait S]   (defaults: SHUTDOWN_FOLLOW_WAIT 1200, SHUTDOWN_FOLLOW_CLEAR_WAIT 300,
#        SHUTDOWN_FOLLOW_EXIT_WAIT 90; the AFD CLI ~/.local/bin/afd; log SHUTDOWN_FOLLOW_LOG)
# Exit: 0 done or nothing to do (cancelled, no shutdown, session gone), 4 a failure after the shutdown.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=remote-session-lib.sh
source "$SCRIPT_DIR/remote-session-lib.sh"

PID="" TOKEN="" DIR="${SHUTDOWN_FOLLOW_DIR:-$HOME/.local/state/shutdown-follow}"
WAIT="${SHUTDOWN_FOLLOW_WAIT:-1200}" CLEAR_WAIT="${SHUTDOWN_FOLLOW_CLEAR_WAIT:-300}" EXIT_WAIT="${SHUTDOWN_FOLLOW_EXIT_WAIT:-90}"
LOG="${SHUTDOWN_FOLLOW_LOG:-$HOME/.claude/logs/shutdown-follow.log}"
AFD_CLI="${SHUTDOWN_FOLLOW_AFD:-$HOME/.local/bin/afd}"
WORDS="" TRANSCRIPT="" OFFSET=0 SID_ARMED="" HINT="" CC="" PROJECT="" SEEN=0 TARGET=none

sf_log() { mkdir -p "${LOG%/*}" 2>/dev/null; local t; printf -v t '%(%FT%T)T' -1; echo "$t watcher pid=$PID token=$TOKEN $*" >> "$LOG" 2>/dev/null; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pid) PID="${2:-}"; shift ;;
            --token) TOKEN="${2:-}"; shift ;;
            --state-dir) DIR="${2:-}"; shift ;;
            --wait) WAIT="${2:-}"; shift ;;
            --clear-wait) CLEAR_WAIT="${2:-}"; shift ;;
            --exit-wait) EXIT_WAIT="${2:-}"; shift ;;
            -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
            *) echo "shutdown-follow: unknown argument '$1'" >&2; exit 2 ;;
        esac
        shift
    done
    [[ "$PID" =~ ^[0-9]+$ && -n "$TOKEN" ]] || { echo "shutdown-follow: --pid <pid> --token <token> required" >&2; exit 2; }
}

# sf_pending — 0 while the state file still names our token (the hook's cancel / re-arm channel)
sf_pending() { [[ -f "$DIR/$PID" && "$(head -n1 "$DIR/$PID" 2>/dev/null)" == "$TOKEN" ]]; }

# sf_read_state — WORDS, TRANSCRIPT, OFFSET, SID_ARMED (the session id that armed us) from the state file (lines 2-5)
sf_read_state() {
    { read -r _; read -r WORDS; IFS= read -r TRANSCRIPT; read -r OFFSET; read -r SID_ARMED; } < "$DIR/$PID" 2>/dev/null
    [[ "$OFFSET" =~ ^[0-9]+$ ]] || OFFSET=0
    [[ -n "$WORDS" ]]
}

sf_done() { sf_pending && rm -f "$DIR/$PID" 2>/dev/null; return 0; }
sf_status() { rs_session_field "$PID" status "$CC"; }
sf_sid() { rs_session_field "$PID" sessionId "$CC"; }

# sf_may_type — read right before every key: still ours (the token), still the session that armed us (its
# record's session id — the user's own /clear fires no prompt hook), and its record neither busy (a prompt is
# running — the user's, drained after the completion) nor waiting (a dialog). 0 go; 2 stand down silently
# (cancelled, already cleared, busy); 1 a dialog (a failure to report). REASON says which.
sf_may_type() {
    local st sid
    sf_pending || { REASON="cancelled"; return 2; }
    sid=$(sf_sid)
    if [[ -n "$sid" && -n "$SID_ARMED" && "$sid" != "$SID_ARMED" ]]; then
        REASON="session already cleared by someone else (record now $sid, armed on $SID_ARMED)"; return 2
    fi
    st=$(sf_status)
    case "$st" in
        busy)    REASON="pid $PID is busy (another prompt is running)"; return 2 ;;
        waiting) REASON="pid $PID shows a dialog (record status waiting)"; return 1 ;;
    esac
    return 0
}

# sf_probe_path — once, at the start: can this watcher type into its session at all? TARGET = rs_input_target;
# 1 with REASON when no path exists (none, or the safety check cannot even read the tty): nothing to wait for.
sf_probe_path() {
    TARGET=$(rs_input_target "$PID") || { REASON="no input path to pid $PID on this machine (no tmux pane, no Konsole tab, not WSL)"; return 1; }
    rs_safety_check "$PID" "$PID" 1 || { REASON="no input path: $RS_REASON"; return 1; }
}

# sf_report <msg> — a failure after the shutdown was seen: the log always; ONE Telegram line while AFK is on
sf_report() {
    sf_log "FAILED: $1"
    [[ -f "$HOME/.afd-afk" && -x "$AFD_CLI" ]] || return 0
    timeout -k 2 20 "$AFD_CLI" notify all "[$PROJECT] shutdown-follow: $1" --channel telegram >/dev/null 2>&1 \
        || sf_log "the Telegram report could not be sent (afd notify failed)"
}

# sf_care_active — the care lib's reader (the deployed copy when the repo's is not beside this script);
# without the lib — a fleet without session caretaking — the file's first word, and no file means off
sf_care_active() {
    local f="${CARE_FILE:-$HOME/.afd-care}" w
    if source "$SCRIPT_DIR/../../global/hooks/lib-care.sh" 2>/dev/null || source "$HOME/.claude/hooks/lib-care.sh" 2>/dev/null; then
        care_paths; care_read && [[ "$CARE_STATE" == active ]]; return
    fi
    { read -r w _ < "$f"; } 2>/dev/null && [[ "$w" == active ]]
}

# sf_wait_shutdown — poll until a turn after OFFSET completed the shutdown (rs_shutdown_turn: HINT = its Next:
# hint) and the record is neither busy nor waiting. 0 ready; 1 no shutdown within WAIT; 2 cancelled; 3 the
# session is gone; 4 the shutdown was seen but the record stayed busy/waiting until WAIT (RS_LAST_STATUS).
sf_wait_shutdown() {
    local end=$(( SECONDS + WAIT )) st h
    RS_LAST_STATUS=""
    while :; do
        sf_pending || return 2
        rs_alive "$PID" || return 3
        if (( SEEN )) || h=$(rs_shutdown_turn "$TRANSCRIPT" "$OFFSET"); then
            (( SEEN )) || { SEEN=1; HINT="$h"; sf_log "shutdown reported in $TRANSCRIPT after byte $OFFSET (Next: ${HINT:-none})"; }
            st=$(sf_status); RS_LAST_STATUS="$st"
            [[ "$st" == busy || "$st" == waiting ]] || return 0
        fi
        (( SECONDS >= end )) && { (( SEEN )) && return 4 || return 1; }
        sleep "$RS_POLL"
    done
}

# sf_decide — the line to type: the shutdown turn's own Next: hint, else the arming keyword; "" = nothing
sf_decide() {
    case "$HINT" in exit) echo /exit; return ;; clear) echo /clear; return ;; esac
    case "$WORDS" in
        cls) echo /clear ;;
        end) echo /exit ;;
        *)   sf_log "no 'Next:' hint and both cls and end armed ($WORDS): nothing typed"; echo "" ;;
    esac
}

# sf_type_line <line> — as remote-session.sh's type_or_die: the input target resolved once, then sf_may_type
# (token, session id, status) right before the clearing keys and the text (rs_submit_type reads the dialog
# guard again before the text) and again right before the Enter. 0 entered; 2 stood down (REASON: cancelled,
# already cleared, busy — the text, when it went in, cleared again); 1 a failure (a dialog, a key not
# delivered; the text cleared again when it went in).
sf_type_line() {
    local tgt rc
    REASON=""
    tgt=$(rs_input_target "$PID")
    sf_may_type; rc=$?
    (( rc )) && { REASON="$REASON — '$1' not typed"; return "$rc"; }
    export SHUTDOWN_FOLLOW_TOKEN="$TOKEN"   # the stamp of our own lines carries it (the hook leaves us alone)
    rs_submit_type "$PID" "$1" "$tgt" || { REASON="$RS_REASON"; return 1; }
    sf_may_type; rc=$?
    (( rc )) && { REASON="'$1' typed but NOT entered: $REASON; $(rs_giveup_clear "$PID" "$tgt")"; return "$rc"; }
    rs_press_enter "$PID" "$tgt" || { REASON="'$1' typed but NOT entered: Enter could not be delivered; $(rs_giveup_clear "$PID" "$tgt")"; return 1; }
    sf_log "typed $1"
}

sf_do_exit() {
    sf_type_line /exit; local rc=$?
    (( rc == 2 )) && { sf_log "$REASON"; return 0; }
    (( rc )) && { sf_report "$REASON"; return 4; }
    if rs_wait_gone "$PID" "$EXIT_WAIT"; then sf_log "done: pid $PID gone after /exit"; return 0; fi
    (( RS_BG_DIALOG )) && { sf_report "/exit typed, but pid $PID is stuck on CC's background-work selector"; return 4; }
    sf_report "/exit typed, but pid $PID is still alive ${EXIT_WAIT}s later"; return 4
}

sf_do_clear() {
    local sid; sid=$(sf_sid)
    sf_type_line /clear; local rc=$?
    (( rc == 2 )) && { sf_log "$REASON"; return 0; }
    (( rc )) && { sf_report "$REASON"; return 4; }
    rs_wait_cleared "$PID" "$sid" "$CLEAR_WAIT" || { sf_report "/clear typed, but pid $PID has not come back with a fresh session within ${CLEAR_WAIT}s"; return 4; }
    sf_log "fresh session $(sf_sid) after /clear"
    if ! sf_care_active; then sf_log "done: caretaking not active, nothing submitted"; return 0; fi
    sf_pending || { sf_log "cancelled before startup"; return 0; }
    export SHUTDOWN_FOLLOW_TOKEN="$TOKEN"
    if rs_submit_line "$PID" startup 2>>"$LOG"; then sf_log "done: startup submitted (${RS_SUBMIT_STATE:-confirmed})"; return 0; fi
    sf_report "startup NOT confirmed after /clear: ${RS_REASON:-rs_submit_line failed}"; return 4
}

main() {
    parse_args "$@"
    sf_pending || exit 0
    sf_read_state || { sf_log "unreadable state file $DIR/$PID"; exit 0; }
    CC=$(rs_cc_dir_of "$PID"); PROJECT=$(rs_session_field "$PID" cwd "$CC"); PROJECT="${PROJECT##*/}"; PROJECT="${PROJECT:-pid $PID}"
    sf_probe_path || { sf_log "$REASON — stopping, nothing to type here"; sf_done; exit 0; }
    sf_log "watching ($WORDS) transcript=$TRANSCRIPT offset=$OFFSET session=$SID_ARMED path=$TARGET wait=${WAIT}s"
    sf_wait_shutdown; local rc=$?
    case "$rc" in
        1) sf_log "no shutdown reported within ${WAIT}s — nothing typed"; sf_done; exit 0 ;;
        2) sf_log "cancelled"; exit 0 ;;
        3) sf_log "pid $PID is gone — nothing to do"; sf_done; exit 0 ;;
        4) sf_report "shutdown seen, but pid $PID stayed '${RS_LAST_STATUS:-?}' for ${WAIT}s — nothing typed"; sf_done; exit 4 ;;
    esac
    local line; line=$(sf_decide); [[ -n "$line" ]] || { sf_done; exit 0; }
    # Q-TYPE-SELF: caller == pid, allow_self=1 — a session typing into itself (see the header). A path existed
    # at the start (sf_probe_path); one gone now — a stranger on the tty, a tty that moved — is a failure.
    rs_safety_check "$PID" "$PID" 1 || { sf_report "$RS_REASON — nothing typed"; sf_done; exit 4; }
    if [[ "$line" == /exit ]]; then sf_do_exit; rc=$?; else sf_do_clear; rc=$?; fi
    sf_done; exit "$rc"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
main "$@"
