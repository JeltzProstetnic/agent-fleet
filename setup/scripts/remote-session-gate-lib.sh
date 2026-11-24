#!/usr/bin/env bash
# remote-session-gate-lib.sh — the TYPING GATE (CFG-1028): keystrokes go into another Claude Code session only
# during a care shift, or when the user explicitly ordered it. Sourced by remote-session-lib.sh (at its end, like
# the submit and follow libs), so every path that types into a session — a remote-session driver, the
# shutdown-follow watcher, a remote power-off — meets it in rs_safety_check; not run.
#
# Keystrokes go into ANOTHER session only
#   (a) during an ACTIVE care shift, typed by the caretaker (Q-TYPE-CALLER): the care state file (~/.afd-care,
#       one line "<state> <epoch> <caretaker pid> ...") says `active` and its caretaker pid (field 3) is alive.
#       It is read through the care machinery's own reader (lib-care.sh, care_read) where that lib exists, else
#       by this lib itself (rs_care_read: first and third word) — a deployment without session caretaking has
#       no such file, so the gate refuses there unless the user ordered the typing. The caller is the caretaker
#       when its claude ancestor (rs_caller_pid) IS that pid, or when it passes that pid as the caretaker marker
#       (a care job runs detached, where no claude is above it). `armed` is not a shift, and neither is `active`
#       with a dead caretaker.
#   (b) on the user's explicit order, passed as --ordered "<the user's words>" (Q-TYPE-EXPLICIT: a per-instance
#       order that names the typing, or one for an action that types by design). The script cannot judge the
#       words; it requires them, and logs them.
# A session typing into ITSELF is not gated (Q-TYPE-SELF): rs_safety_check skips the gate when caller == pid
# (a driver's --self, the shutdown-follow watcher, a power-off /exit-ing its own caller). Keystrokes only:
# messages between sessions are not typing (Q-TYPE-SENDMSG). After `care off` the shift is over — there is no
# tombstone window (the caretaker's "caretaking ended" line goes as a message, not as keys).
# Every refusal and every --ordered use is logged (rs_gate_log): RS_GATE_LOG, default
# ~/.claude/logs/remote-session.log. A "gate passed" line means the gate was PASSED for that target, not that a
# key was typed: it is written before the tty-sharer check, and start/relaunch write one before launching and one
# for the new pid. Control characters in the logged words become spaces (one line per decision; CFG-1083 F7).
# Overridable for tests: RS_GATE_LOG, RS_GATE_WHAT (the action named in the log), the care lib's CARE_FILE
# (default ~/.afd-care — tests sandbox HOME).
#
# The pass is ARMED, not implied (CFG-1083 F1): rs_safety_check records the pid it passed for in RS_GATE_OK
# (rs_gate_arm), and every key primitive — rs_type_text, rs_press_enter, rs_clear_input, rs_type_line,
# rs_inject_wsl, remote-poweroff's type_line / press_enter — refuses (rc 3, RS_REASON, a "refused key" log line)
# a pid that is not RS_GATE_OK (rs_gate_armed). Sourcing the lib gets nobody past the gate.

RS_CARE_STATE="" RS_CARE_OWNER=""   # rs_care_read
RS_GATE_OK=""                       # the one pid the gate was last passed for (rs_safety_check → rs_gate_arm)

# rs_gate_log <text> — one line in the gate log (control characters in <text> become spaces); never fails the caller
rs_gate_log() {
    local f t w="$*"; f="${RS_GATE_LOG:-$HOME/.claude/logs/remote-session.log}"
    mkdir -p "${f%/*}" 2>/dev/null; printf -v t '%(%FT%T)T' -1
    echo "$t gate ${w//[[:cntrl:]]/ }" >> "$f" 2>/dev/null; return 0
}

# rs_gate_arm <pid> — the gate was passed for <pid>: the key primitives may type into it (and into no other)
rs_gate_arm() { RS_GATE_OK="${1:-}"; }

# rs_gate_armed <pid> — 0 when the gate was passed for exactly <pid>; else 3, RS_REASON and a log line (CFG-1083 F1)
rs_gate_armed() {
    [[ -n "${1:-}" && "$1" == "$RS_GATE_OK" ]] && return 0
    RS_REASON="refused: no gate passed for pid ${1:-?} (rs_safety_check ${RS_GATE_OK:+passed for pid $RS_GATE_OK, }not for it) — a key reaches a session only after its gate; nothing typed"
    rs_gate_log "refused key → pid ${1:-?}: $RS_REASON"
    return 3
}

# rs_care_read — RS_CARE_STATE / RS_CARE_OWNER from the care state file through the care lib's reader (the repo
# copy beside this lib, else the deployed one); without the lib — a fleet without session caretaking — the
# line's first and third word. Both empty (and 1) when there is no state or it is malformed: both mean off.
rs_care_read() {
    local f w _e o
    RS_CARE_STATE="" RS_CARE_OWNER=""
    if declare -F care_read >/dev/null 2>&1 || source "$RS_LIB_DIR/../../global/hooks/lib-care.sh" 2>/dev/null \
        || source "$HOME/.claude/hooks/lib-care.sh" 2>/dev/null; then
        care_paths; care_read || return 1
        RS_CARE_STATE="$CARE_STATE" RS_CARE_OWNER="$CARE_OWNER"; return 0
    fi
    f="${CARE_FILE:-$HOME/.afd-care}"
    { read -r w _e o _ < "$f"; } 2>/dev/null || return 1
    [[ "$w" == armed || "$w" == active ]] || return 1
    RS_CARE_STATE="$w" RS_CARE_OWNER="$o"
}

# rs_care_caretaker <caller pid> <caretaker marker> — 0 when a care shift is ACTIVE with a live caretaker and
# <caller> or <marker> is that caretaker; else 1 with RS_REASON saying what is missing.
rs_care_caretaker() {
    local caller="${1:-}" marker="${2:-}"
    [[ "$caller" == 0 ]] && caller=""
    rs_care_read
    if [[ "$RS_CARE_STATE" != active ]]; then
        RS_REASON="no care shift is active${RS_CARE_STATE:+ (care state: $RS_CARE_STATE)}"; return 1
    fi
    if ! [[ "$RS_CARE_OWNER" =~ ^[0-9]+$ ]]; then
        RS_REASON="care state is active but the care line names no caretaker pid (field 3: ${RS_CARE_OWNER:-empty}) — no care shift"; return 1
    fi
    if ! rs_alive "$RS_CARE_OWNER"; then
        RS_REASON="care state is active but its caretaker pid $RS_CARE_OWNER is gone — no care shift"; return 1
    fi
    [[ -n "$caller" && "$caller" == "$RS_CARE_OWNER" ]] && return 0
    [[ -n "$marker" && "$marker" == "$RS_CARE_OWNER" ]] && return 0
    RS_REASON="a care shift is active, but the caller (claude pid ${caller:-unknown}${marker:+, caretaker marker $marker}) is not the caretaker (pid $RS_CARE_OWNER) — only the caretaker types during a shift"
    return 1
}

# rs_typing_allowed <target> <caller pid> <ordered words> <caretaker marker> — the gate for typing into <target>
# (a label for the log: "pid N", "new session", "other sessions"): 0 when the user's words were passed or the
# caller is the caretaker of an active shift, logged as "gate passed" (passed, not typed); else 3 with RS_REASON —
# one line naming --ordered "<the user's words>" as the way for an order the user gave — and a log line.
# RS_GATE_WHAT names the action in the log (default: typing). The pass is recorded for the keys by the CALLER
# (rs_safety_check → rs_gate_arm).
rs_typing_allowed() {
    local tgt="${1:-?}" caller="${2:-}" ordered="${3:-}" marker="${4:-}" what="${RS_GATE_WHAT:-typing}"
    [[ "$caller" == 0 ]] && caller=""
    if [[ -n "${ordered//[[:space:]]/}" ]]; then
        rs_gate_log "passed $what → $tgt caller=${caller:-none}${marker:+ marker=$marker} by=ordered words=\"$ordered\""
        return 0
    fi
    if rs_care_caretaker "$caller" "$marker"; then
        rs_gate_log "passed $what → $tgt caller=${caller:-none}${marker:+ marker=$marker} by=caretaker (care active, caretaker pid $RS_CARE_OWNER)"
        return 0
    fi
    RS_REASON="refused: $RS_REASON; typing into a Claude Code session is for the caretaker during an active care shift or for an order the user gave — pass --ordered \"<the user's words>\" for that order (CFG-1028) — nothing typed"
    rs_gate_log "refused $what → $tgt caller=${caller:-none}${marker:+ marker=$marker}: $RS_REASON"
    return 3
}
