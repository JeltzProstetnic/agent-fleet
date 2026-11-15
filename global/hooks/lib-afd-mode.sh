#!/usr/bin/env bash
# lib-afd-mode.sh — every live session learns of an AFK or DND switch made elsewhere (CFG-1036).
#
# ~/.afd-afk (AFK) and ~/.afd-dnd (DND, CFG-1035) are machine-wide flags: a switch typed in one
# session, sent from Telegram or run in a shell changes them for every session, and nothing told the
# others (2026-11-14: a caretaker told the user "AFK mode is still on" hours after he had switched it
# off in another session). Each hook turn — a prompt (afk-deactivate.sh), a tool call (afd-relay.sh)
# and an idle wake (afd-idle-wake.sh) — compares the flags with what THIS session saw last, a one-line
# marker $AFD_MSG_DIR/.mode/<session id> ("<afk on|off> <dnd on|off>"), and sets AFD_MODE_LINES to
# one line per mode switched since, e.g.
#   AFK_CHANGED: off (switched 14:32) — AFK is OFF now: …
# Only the on/off state counts (a re-switch to the same state is no change). A session's first turn
# records the state, with one AFK_STATE / DND_STATE line for each mode that is already on (silent
# when both are off); afd_mode_seen records a switch the session made itself, so it is not echoed
# back. Fast path (nothing changed): pure bash — two -f tests and one read, no subprocess;
# callers read AFD_MODE_LINES instead of capturing output, which would fork.
# Switch time: an "on" flag holds its switch time; a switch-off leaves it in <flag>.off
# (afd_mode_stamp_off, `afd afk|dnd off`, the Telegram switch), shown only when that stamp is newer
# than this session's marker — otherwise the line says when the change was noticed.
# LIMITATION: both flags are per machine; sessions on another machine never see this one's switch,
# and a Telegram switch lands on whichever machine polls first (`dnd` is acknowledged with its host).

[[ "${_LIB_AFD_MODE_LOADED:-}" == "true" ]] && return 0
_LIB_AFD_MODE_LOADED="true"

# afd_mode_now — AFD_MODE_NOW = "<afk on|off> <dnd on|off>" from the flags (pure bash).
afd_mode_now() {
    local a=off d=off
    [[ -f "$HOME/.afd-afk" ]] && a=on
    [[ -f "$HOME/.afd-dnd" ]] && d=on
    AFD_MODE_NOW="$a $d"
}

# _afd_mode_marker <sid> — AFD_MODE_MARKER = that session's marker; 1 without a session id.
_afd_mode_marker() {
    AFD_MODE_MARKER=""
    [[ -n "${1-}" && "$1" != nosession ]] || return 1
    AFD_MODE_MARKER="${AFD_MSG_DIR:-$HOME/.afd-msgs}/.mode/${1//[^A-Za-z0-9_-]/_}"
}

# afd_mode_check <sid> — AFD_MODE_LINES = one line per mode switched since this session's last turn;
# empty when nothing changed, on the session's first turn, or without a session id.
afd_mode_check() {
    local seen=""
    AFD_MODE_LINES=""
    _afd_mode_marker "${1-}" || return 0
    afd_mode_now
    { IFS= read -r seen < "$AFD_MODE_MARKER"; } 2>/dev/null
    [[ "$seen" == "$AFD_MODE_NOW" ]] && return 0
    if [[ -n "$seen" ]]; then
        _afd_mode_report "$seen"
    else                                  # first turn: one state line for each mode that is ON
        [[ "${AFD_MODE_NOW% *}" == on ]] && _afd_mode_line AFK on "$HOME/.afd-afk" STATE
        [[ "${AFD_MODE_NOW#* }" == on ]] && _afd_mode_line DND on "$HOME/.afd-dnd" STATE
    fi
    # A change that cannot be recorded is not reported: it would repeat on every turn (re-review 3).
    _afd_mode_write || AFD_MODE_LINES=""
    return 0
}

# afd_mode_seen <sid> [afk|dnd] — record that session's own switch silently. With a field, only
# that mode is recorded; the other keeps what the session last saw, so a switch of it made
# elsewhere meanwhile is still told (review #7). Without a field (or without a marker) both.
afd_mode_seen() {
    local seen="" a d na nd
    _afd_mode_marker "${1-}" || return 0
    afd_mode_now
    if [[ -n "${2-}" ]] && { IFS= read -r seen < "$AFD_MODE_MARKER"; } 2>/dev/null && [[ -n "$seen" ]]; then
        read -r a d <<< "$seen"
        read -r na nd <<< "$AFD_MODE_NOW"
        case "$2" in afk) a=$na ;; dnd) d=$nd ;; esac
        AFD_MODE_NOW="$a $d"
    fi
    _afd_mode_write
    return 0
}

# afd_mode_held_note <sid> — AFD_MODE_HELD = one line when DND is off but messages held during it
# were never sent: a `dnd off` cut short on the Telegram path, whose failure token the background
# hooks discard, would leave them for days (re-review 5). Once per session per change of the held
# files: <marker>.held is touched when the line is given. A claim of a running `dnd off` is not
# counted. Pure bash; nothing when the marker cannot be written (it would repeat every turn).
afd_mode_held_note() {
    local f p m newer=""
    AFD_MODE_HELD=""
    [[ -f "$HOME/.afd-dnd" ]] && return 0
    compgen -G "$HOME/.afd-dnd.held*" >/dev/null || return 0
    _afd_mode_marker "${1-}" || return 0
    m="$AFD_MODE_MARKER.held"
    for f in "$HOME"/.afd-dnd.held*; do
        [[ -s "$f" ]] || continue
        if [[ "$f" == *.sending.* ]]; then
            p="${f##*.sending.}"; p="${p%%.*}"
            [[ "$p" =~ ^[0-9]+$ && -d "/proc/$p" ]] && continue
        fi
        [[ -f "$m" && ! "$f" -nt "$m" ]] && continue
        newer=1; break
    done
    [[ -n "$newer" ]] || return 0
    { : > "$m"; } 2>/dev/null || return 0
    AFD_MODE_HELD="DND_HELD: DND is off, but messages held while it was on were never sent (a dnd off was cut short). Run afd dnd off to send the digest."
}

# afd_mode_stamp_off <flag> — leave the switch-off time beside a flag that was just removed.
afd_mode_stamp_off() {
    date '+%Y-%m-%dT%H:%M:%S%z' > "$1.off" 2>/dev/null || true
}

_afd_mode_report() {
    local wa wd na nd
    read -r wa wd <<< "$1"
    read -r na nd <<< "$AFD_MODE_NOW"
    [[ "$wa" == "$na" ]] || _afd_mode_line AFK "$na" "$HOME/.afd-afk"
    [[ "$wd" == "$nd" ]] || _afd_mode_line DND "$nd" "$HOME/.afd-dnd"
    return 0
}

# _afd_mode_line <AFK|DND> <on|off> <flag> [CHANGED|STATE] — append one line to AFD_MODE_LINES.
_afd_mode_line() {
    local t="" when="" how=switched meaning=""
    if [[ "$2" == on ]]; then
        { IFS= read -r t < "$3"; } 2>/dev/null
    elif [[ -f "$3.off" && "$3.off" -nt "$AFD_MODE_MARKER" ]]; then
        { IFS= read -r t < "$3.off"; } 2>/dev/null
    fi
    [[ -n "$t" ]] && when=$(_afd_mode_hhmm "$t")
    if [[ -z "$when" ]]; then how=noticed; when=$(date +%H:%M); fi
    case "$1 $2" in
        "AFK on")  meaning="AFK is ON now: the user is away and AskUserQuestion goes to Telegram" ;;
        "AFK off") meaning="AFK is OFF now: the user is back at a console and questions go there" ;;
        "DND on")  meaning="DND is ON now: afd notify holds every message for one digest at dnd off; only afd notify --critical gets through, for a critical alert (disk or backup failure, security) or when you were meant to work unattended and can no longer work. Do not ask: write each question into your handover with a stable ID and keep working" ;;
        "DND off") meaning="DND is OFF now: messages and questions reach the user again" ;;
    esac
    AFD_MODE_LINES+="${AFD_MODE_LINES:+$'\n'}${1}_${4:-CHANGED}: $2 ($how $when) — $meaning. Trust this over any earlier mention of the mode."
}

# _afd_mode_hhmm <timestamp> — "HH:MM" today, "YYYY-MM-DD HH:MM" otherwise; nothing if unreadable
# (BSD date has no -d: the line then says when the change was noticed).
_afd_mode_hhmm() {
    local out today
    out=$(date -d "$1" '+%F %H:%M' 2>/dev/null) || return 0
    today=$(date +%F)
    echo "${out#"$today "}"
}

# _afd_mode_write — AFD_MODE_NOW into AFD_MODE_MARKER atomically; 1 on any failure (callers then
# report nothing). A new marker also prunes markers no session has changed in 30 days (one per
# session id, so they would pile up). Every error stays out of the hook output.
_afd_mode_write() {
    local d="${AFD_MODE_MARKER%/*}" tmp
    [[ -d "$d" ]] || mkdir -p "$d" 2>/dev/null || return 1
    [[ -f "$AFD_MODE_MARKER" ]] || find "$d" -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null
    tmp="$d/.${AFD_MODE_MARKER##*/}.tmp.$$"
    { printf '%s\n' "$AFD_MODE_NOW" > "$tmp"; } 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv -f "$tmp" "$AFD_MODE_MARKER" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}
