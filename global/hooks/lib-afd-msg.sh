#!/usr/bin/env bash
# lib-afd-msg.sh — route consumed Telegram messages to the project they address.
#
# `afd messages` CONSUMES every pending Telegram message on the server, so the
# first session whose hook polls receives all of them — including answers meant
# for a different session (2026-10-18: an "@<project> …" answer was eaten by one
# session while the project it named sat blocked on its question). Every consumer therefore files each
# message into a per-project queue, and each session takes only its own:
#   - `@<project> …`  → that project (a unique name prefix works: `@cfg`)
#   - untagged        → the shared pool while any relay waits on a Telegram question
#                        (marker $AFD_MSG_DIR/.waiting/<project>, CFG-779: the waiting
#                        relays claim from it, lib-afd-pool.sh), else the consumer
#   - unknown `@name` → the consumer, text intact (e.g. a bot mention)
#   - a message that is only `afk` / `afk on` / `afk off` (optionally after an
#     @tag) switches the global AFK flag instead of being queued
#
# Queue: $AFD_MSG_DIR/<project>.jsonl (default ~/.afd-msgs), one `afd messages`
# JSON line per message. Project = lowercased name of the main git repo of a dir.
# Every function is a silent no-op when the afd CLI is absent.
#
# LIMITATION: the queue is per machine. A message consumed on one machine cannot
# reach a session on another; that needs a server-side project filter (CFG-770).

[[ "${_LIB_AFD_MSG_LOADED:-}" == "true" ]] && return 0

_afd_msg_dir() { echo "${AFD_MSG_DIR:-$HOME/.afd-msgs}"; }

# Pool, claims and locked queue operations (CFG-779/781); every function here that
# writes a queue goes through its lock. The load guard is set only once this succeeded,
# so a failed load does not poison the next attempt in the same shell.
source "$(dirname "${BASH_SOURCE[0]}")/lib-afd-pool.sh" || return 1
_LIB_AFD_MSG_LOADED="true"

# afd_project_of <dir> — lowercased name of the MAIN git repo containing <dir>
# (a worktree resolves to its main repo), else of <dir> itself.
afd_project_of() {
    local dir="${1:-$PWD}" common root
    common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    if [[ -n "$common" && "$(basename "$common")" == ".git" ]]; then
        root=$(dirname "$common")
    else
        root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || root="$dir"
    fi
    basename "$root" | tr '[:upper:]' '[:lower:]'
}

# _afd_known_projects — lowercased project dir names under $AFD_PROJECT_ROOTS
# (space-separated dirs, default $HOME).
_afd_known_projects() {
    local r d
    for r in ${AFD_PROJECT_ROOTS:-$HOME}; do
        [[ -d "$r" ]] || continue
        for d in "$r"/*/; do
            [[ -d "$d" ]] && basename "$d" | tr '[:upper:]' '[:lower:]'
        done
    done | sort -u
}

# _afd_resolve_target <name> — the known project <name> means (exact, else a
# unique prefix), or nothing.
_afd_resolve_target() {
    local want="$1" known matches
    known=$(_afd_known_projects)
    if grep -qxF -- "$want" <<< "$known"; then echo "$want"; return; fi
    matches=$(grep -E "^$(printf '%s' "$want" | sed 's/[.]/\\./g')" <<< "$known" || true)
    [[ -n "$matches" && $(wc -l <<< "$matches") -eq 1 ]] && echo "$matches"
}

# afd_short_name <project> — the shortest prefix (3+ chars) that _afd_resolve_target
# maps back to <project>, for the "@<tag>" hint in a Telegram question; empty when no
# tag routes to <project> (it is not under AFD_PROJECT_ROOTS).
afd_short_name() {
    local p="$1" n
    [[ "$(_afd_resolve_target "$p")" == "$p" ]] || return 0   # no tag routes here
    for (( n = 3; n < ${#p}; n++ )); do
        [[ "$(_afd_resolve_target "${p:0:n}")" == "$p" ]] && { echo "${p:0:n}"; return; }
    done
    echo "$p"
}

# afd_marker_write <marker> <content> — write a waiting marker atomically (dot-prefixed temp
# file in the same dir, then rename): no reader ever sees it empty or half-written.
afd_marker_write() {
    local tmp; tmp="$(dirname "$1")/.$(basename "$1").tmp.$$"
    printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null
}

# _afd_marker_live <marker> — 0 while the relay that wrote it ("<pid> <question id>")
# is alive. A dead relay's marker (SIGKILL skips its EXIT trap) is removed here. An EMPTY
# marker is not live but is never deleted: a truncating rewrite once let a reader delete a
# live relay's marker and demote it to non-waiter (review 2026-10-25).
_afd_marker_live() {
    local pid
    pid=$(cut -d' ' -f1 "$1" 2>/dev/null)
    [[ -n "$pid" ]] || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && return 0
    rm -f "$1"
    return 1
}

# _afd_live_waiters — every project whose relay is waiting on a Telegram question, one
# per line (dead relays' markers are removed on the way).
_afd_live_waiters() {
    local w="$(_afd_msg_dir)/.waiting" f
    [[ -d "$w" ]] || return 0
    for f in "$w"/*; do
        [[ -f "$f" ]] && _afd_marker_live "$f" && basename "$f"
    done
    return 0
}

# _afd_afk_switch <on|off> — set or clear the AFK flag from Telegram, logged.
_afd_afk_switch() {
    if [[ "$1" == on ]]; then
        date -Iseconds > "$HOME/.afd-afk" 2>/dev/null
    else
        rm -f "$HOME/.afd-afk"
    fi
    mkdir -p "$HOME/.claude/logs" 2>/dev/null
    echo "$(date +%Y-%m-%dT%H:%M:%S%z) afk-$1 by=telegram" >> "$HOME/.claude/logs/afk.log" 2>/dev/null
}

# afd_route_messages <me> — consume pending messages, file each into its queue.
# Prints "afk:on"/"afk:off" for a Telegram AFK switch, then every OTHER project
# it queued messages for, once each (the pool is not a project and is not printed).
afd_route_messages() {
    local me="$1" cli="$HOME/.local/bin/afd" dir line text target waiters raw foreign="" cmd status="" bare
    [[ -x "$cli" && -n "$me" ]] || return 0
    dir=$(_afd_msg_dir)
    raw=$(timeout -k 2 3 "$cli" messages 2>/dev/null) || true
    [[ -n "$raw" ]] || return 0
    mkdir -p "$dir"
    waiters=$(_afd_live_waiters)
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        text=$(printf '%s' "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null)
        cmd=$(printf '%s' "$text" | sed -E 's/^@[A-Za-z0-9_.-]+[[:space:]]*//; s/^[[:space:]]+//; s/[[:space:]!.]+$//' | tr '[:upper:]' '[:lower:]')
        case "$cmd" in
            afk|"afk on") _afd_afk_switch on;  status="afk:on";  continue ;;
            "afk off")    _afd_afk_switch off; status="afk:off"; continue ;;
        esac
        # A bare "@project" (nothing, or only a "#number", after the tag) while a relay waits
        # is a redirect verdict for that relay's ask-back, not a message for the project: it
        # is pooled too.
        target=""; bare=false
        [[ "$cmd" =~ ^(#[0-9]+[[:space:]]*)*$ ]] && bare=true
        if [[ "$text" =~ ^@([A-Za-z0-9_.-]+) ]] && { ! $bare || [[ -z "$waiters" ]]; }; then
            target=$(_afd_resolve_target "$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')")
        elif [[ -n "$waiters" ]]; then
            afd_pool_add "$line"; continue   # a waiting relay claims it (CFG-779)
        fi
        target="${target:-$me}"
        _afd_locked _afd_append_line "$dir/$target.jsonl" "$line"
        [[ "$target" != "$me" && " $foreign " != *" $target "* ]] && foreign="$foreign $target"
    done <<< "$raw"
    [[ -n "$status" ]] && echo "$status"
    for target in $foreign; do echo "$target"; done
    return 0
}

# afd_question_waiting <me> — true while <me>'s AskUserQuestion relay waits for a
# Telegram answer. The relay then owns the queue: any other consumer taking from it
# could eat the answer and leave the relay blocked (2026-10-20, #406/#408). Liveness
# comes from the relay pid in the marker, so a killed relay never silences a project.
afd_question_waiting() {
    local m
    m="$(_afd_msg_dir)/.waiting/$1"
    [[ -n "$1" && -f "$m" ]] && _afd_marker_live "$m"
}

# afd_claude_pid — the Claude Code process this hook runs under: the nearest
# ancestor whose command name starts with "claude". Empty when there is none.
afd_claude_pid() {
    local p=$PPID c
    while [[ -n "$p" && "$p" -gt 1 ]]; do
        c=$(cat "/proc/$p/comm" 2>/dev/null) || return 1
        [[ "$c" == claude* ]] && { echo "$p"; return 0; }
        p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    done
    return 1
}

# afd_take_messages <me> — print and remove this project's queued lines, plus the untagged
# pool once no relay waits any more (zero waiters: untagged belongs to the consumer, as it
# did before the pool), or the pooled lines every live waiter has already rejected.
# Consumers other than the waiting relay check afd_question_waiting first; the relay itself
# peeks and deletes by id (lib-afd-ask.sh) and never takes.
afd_take_messages() {
    local me="$1" live
    [[ -n "$me" ]] || return 0
    _afd_locked _afd_take_file "$(_afd_msg_dir)/$me.jsonl"
    live=$(_afd_live_waiters)
    if [[ -z "$live" ]]; then
        _afd_locked _afd_take_file "$(_afd_pool_file)"
    else
        _afd_locked _afd_pool_take_rejected "$live"
    fi
    return 0
}

# afd_message_text <json line> — the message text with a leading @<project> stripped.
afd_message_text() {
    printf '%s' "$1" | python3 -c "
import sys, json, re
m = json.load(sys.stdin).get('message', '')
print(re.sub(r'^@[A-Za-z0-9_.-]+[\s:,]*', '', m).strip())" 2>/dev/null
}

# afd_message_id <json line> — the numeric id, or 0.
afd_message_id() {
    printf '%s' "$1" | python3 -c "
import sys, json
try: print(int(json.load(sys.stdin).get('id', 0)))
except Exception: print(0)" 2>/dev/null
}

# afd_wake_hint <me> <session_id> — CFG-776. A session drains its queue only on its
# own next prompt, so a message filed for an IDLE session waits forever unless some
# other session wakes it (2026-10-19: MG's @aiware messages sat 10+ min). Hooks
# cannot call SendMessage, so every hook that sees the model prints this hint: one
# line naming each OTHER project whose queue has been undelivered for longer than
# AFD_WAKE_AFTER seconds (default 30), at most once per session per message id.
# Fast path: no queue files → no output, no python.
afd_wake_hint() {
    local me="$1" sid="${2:-nosession}" dir q p after now told ids new out=""
    dir=$(_afd_msg_dir)
    compgen -G "$dir/*.jsonl" >/dev/null || return 0
    after="${AFD_WAKE_AFTER:-30}"; now=$(date +%s)
    told="$dir/.told/${sid//[^A-Za-z0-9_-]/_}"
    for q in "$dir"/*.jsonl; do
        p=$(basename "$q" .jsonl)
        [[ "$p" == "$me" || ! -s "$q" ]] && continue
        (( now - $(stat -c %Y "$q" 2>/dev/null || echo "$now") >= after )) || continue
        ids=$(python3 -c "
import sys, json
for l in open(sys.argv[1]):
    try: print(int(json.loads(l).get('id', 0)))
    except Exception: pass" "$q" 2>/dev/null)
        new=""
        for id in $ids; do
            grep -qx "$p:$id" "$told" 2>/dev/null && continue
            new="$new #$id"
            mkdir -p "$dir/.told" && echo "$p:$id" >> "$told"
        done
        [[ -n "$new" ]] && out="$out @$p:$new;"
    done
    [[ -n "$out" ]] || return 0
    echo "TELEGRAM_UNDELIVERED (CFG-776):${out%;} — Telegram message(s) from MG are queued for another project whose session has not picked them up (it is probably idle; a session drains its queue only on its next prompt). Do not act on them. Run ListAgents and SendMessage each named project's session: \"Telegram message(s) are queued for you; your prompt hook delivers them.\" If no such session is live, tell MG: afd notify all \"[$me] @<project> has no live session; your message waits for its next start\" --channel telegram"
}
