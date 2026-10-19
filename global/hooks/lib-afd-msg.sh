#!/usr/bin/env bash
# lib-afd-msg.sh — route consumed Telegram messages to the project they address.
#
# `afd messages` CONSUMES every pending Telegram message on the server, so the
# first session whose hook polls receives all of them — including answers meant
# for a different session (2026-10-18: an "@<project> …" answer was eaten by one
# session while the project it named sat blocked on its question). Every consumer therefore files each
# message into a per-project queue, and each session takes only its own:
#   - `@<project> …`  → that project (a unique name prefix works: `@cfg`)
#   - untagged        → the single project waiting on a Telegram question, if
#                        exactly one is (marker $AFD_MSG_DIR/.waiting/<project>),
#                        else the consumer
#   - unknown `@name` → the consumer, text intact (e.g. a bot mention)
#
# Queue: $AFD_MSG_DIR/<project>.jsonl (default ~/.afd-msgs), one `afd messages`
# JSON line per message. Project = lowercased name of the main git repo of a dir.
# Every function is a silent no-op when the afd CLI is absent.
#
# LIMITATION: the queue is per machine. A message consumed on one machine cannot
# reach a session on another; that needs a server-side project filter (CFG-770).

[[ "${_LIB_AFD_MSG_LOADED:-}" == "true" ]] && return 0
_LIB_AFD_MSG_LOADED="true"

_afd_msg_dir() { echo "${AFD_MSG_DIR:-$HOME/.afd-msgs}"; }

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

# _afd_single_waiter — the project waiting on a Telegram question, if exactly one.
_afd_single_waiter() {
    local w="$(_afd_msg_dir)/.waiting" files
    [[ -d "$w" ]] || return 0
    files=$(ls -1 "$w" 2>/dev/null)
    [[ -n "$files" && $(wc -l <<< "$files") -eq 1 ]] && echo "$files"
}

# afd_route_messages <me> — consume pending messages, file each into its queue.
# Prints every OTHER project it queued messages for, once each.
afd_route_messages() {
    local me="$1" cli="$HOME/.local/bin/afd" dir line text target waiter raw foreign=""
    [[ -x "$cli" && -n "$me" ]] || return 0
    dir=$(_afd_msg_dir)
    raw=$(timeout -k 2 3 "$cli" messages 2>/dev/null) || true
    [[ -n "$raw" ]] || return 0
    mkdir -p "$dir"
    waiter=$(_afd_single_waiter)
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        text=$(printf '%s' "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null)
        target=""
        if [[ "$text" =~ ^@([A-Za-z0-9_.-]+) ]]; then
            target=$(_afd_resolve_target "$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')")
        elif [[ -n "$waiter" ]]; then
            target="$waiter"
        fi
        target="${target:-$me}"
        printf '%s\n' "$line" >> "$dir/$target.jsonl"
        [[ "$target" != "$me" && " $foreign " != *" $target "* ]] && foreign="$foreign $target"
    done <<< "$raw"
    for target in $foreign; do echo "$target"; done
    return 0
}

# afd_take_messages <me> — print and remove this project's queued lines.
afd_take_messages() {
    local me="$1" dir q tmp
    [[ -n "$me" ]] || return 0
    dir=$(_afd_msg_dir); q="$dir/$me.jsonl"
    [[ -s "$q" ]] || return 0
    tmp="$q.taking.$$"
    mv -f "$q" "$tmp" 2>/dev/null || return 0   # atomic: a concurrent append lands in a new file
    cat "$tmp"
    rm -f "$tmp"
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
