#!/usr/bin/env bash
# lib-afd-ask.sh — how a waiting AskUserQuestion relay picks its Telegram answer (CFG-779).
#
# A tagged line for this project, or one the user redirected here, sits in the project's own
# queue and is the answer. An untagged line sits in the pool (lib-afd-pool.sh) and is CLAIMED first:
#   tier 0  a Telegram reply to the question itself (reply_to == Q): taken, no ask-back
#   tier 1  the text has one token per question (for a single question: any text): claim
#   tier 2  any newer line, once it has sat in the pool for AFD_ASK_GRACE s (default 20): claim
# A line with no text after its @tag is never a candidate. A claimed line is taken at once when
# no other relay waits; otherwise the relay asks "[proj] was #M for me? y / n / @project alone"
# (--type info, so a Telegram d cannot hit it, CFG-771c) and the marker becomes
# "<pid> Q claimed M C". The verdict (lib-afd-scan.sh) is a pooled line that explicitly answers
# the ask-back — a Telegram reply to C, or one naming #C or #M — read by its first token
# (yes-word, no-word, @project; anything else leaves the line alone), or, only while no OTHER
# ask-back is open, a newer bare verdict: strictly a sole y/n token or a sole @tag (decided
# 2026-10-25, "require a target": with another ask-back open the text says
# "y #M / n #M / @project #M", a bare y is nobody's and earns one nudge). y takes M and confirms
# "[proj] working on #M"; n releases M marked rejected by proj; a project re-files M into that
# queue flagged redirected (taken there without another ask-back). Lines another live relay
# claimed, or reads as its verdict, are left alone. 2026-10-24: one project took #472/#484.
#
# Sourced by afd-relay.sh, whose globals it reads: ME, NOTIF_ID (Q), INPUT, MARKER, AFD_CLI.
# Keeps ASK_M / ASK_C (the pending claim and ask-back) and sets ANSWER, ANSWER_ID,
# ANSWER_HOW (tagged | redirected | reply_to | single | confirmed).

[[ "${_LIB_AFD_ASK_LOADED:-}" == "true" ]] && return 0
source "$(dirname "${BASH_SOURCE[0]}")/lib-afd-msg.sh" || return 1
source "$(dirname "${BASH_SOURCE[0]}")/lib-afd-scan.sh" || return 1   # the pool scan
_LIB_AFD_ASK_LOADED="true"

# afd_ask_map <hook input json> <answer> — CFG-773: the allow decision with updatedInput.answers,
# so CC shows the user's answer instead of "PreToolUse hook error". A digit picks that option,
# a reply matching a label (any case) is that label, anything else is free text; with several
# questions the reply must be one token per question. Prints nothing and fails when unmappable.
afd_ask_map() {
    printf '%s' "$1" | ANSWER="$2" python3 -c '
import json, os, sys
t = json.load(sys.stdin).get("tool_input", {})
qs, a = t.get("questions") or [], os.environ["ANSWER"].strip()
def pick(q, tok):
    opts = [o.get("label", "") for o in q.get("options") or []]
    if tok.isdigit() and 1 <= int(tok) <= len(opts):
        return opts[int(tok) - 1]
    for o in opts:
        if o.lower() == tok.lower():
            return o
    return tok
if not qs or not a:
    sys.exit(1)
if len(qs) == 1:
    answers = {qs[0]["question"]: pick(qs[0], a)}
else:
    toks = a.split()
    if len(toks) != len(qs):
        sys.exit(1)
    answers = {q["question"]: pick(q, tok) for q, tok in zip(qs, toks)}
out = dict(t, answers=answers)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
      "permissionDecision": "allow",
      "permissionDecisionReason": "Answered via Telegram (AFK)",
      "updatedInput": out}}))' 2>/dev/null
}

# _afd_ask_send <text> — "[ME] <text>" to Telegram as an info notification; prints its id.
_afd_ask_send() {
    local out
    out=$(timeout -k 2 15 "$AFD_CLI" notify all "[$ME] $1" --channel telegram --type info 2>&1) || true
    grep -oE '#[0-9]+' <<< "$out" | head -1 | tr -d '#'
}

# _afd_ask_mark [claimed M C] — rewrite the marker (atomically) while it is still this relay's.
_afd_ask_mark() {
    [[ "$(cut -d' ' -f1 "$MARKER" 2>/dev/null)" == "$$" ]] && afd_marker_write "$MARKER" "$$ $NOTIF_ID${1:+ $1}"
    return 0
}

_afd_line_true() { # _afd_line_true <json line> <field> — 0 when the field is truthy
    [[ "$(printf '%s' "$1" | python3 -c 'import json,sys; print(1 if json.load(sys.stdin).get(sys.argv[1]) else "")' "$2" 2>/dev/null)" == 1 ]]
}

# afd_ask_begin — once the question is sent: count its questions, no claim pending yet.
afd_ask_begin() {
    ASK_QN=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("tool_input",{}).get("questions") or []) or 1)' 2>/dev/null || echo 1)
    ASK_M=""; ASK_C=""; ANSWER=""; ANSWER_ID=""; ANSWER_HOW=""
}

# afd_ask_step — one wait-loop cycle after afd_route_messages: 0 with ANSWER set, else 1.
# While an ask-back is out, a reply to the question itself still wins (tier 0 is decided).
afd_ask_step() {
    _afd_ask_own_answer && return 0
    if [[ -z "$ASK_M" ]]; then _afd_ask_claim; else _afd_ask_direct_reply || _afd_ask_verdict; fi
}

_afd_ask_direct_reply() {
    local pick tier id npend
    pick=$(ONLY0=1 _afd_ask_scan candidate); [[ -n "$pick" ]] || return 1
    read -r tier id npend <<< "$pick"
    afd_claim "$id" "$ME" || return 1
    afd_release_claim "$ASK_M"; ASK_M=""; ASK_C=""; _afd_ask_mark
    _afd_ask_take_pooled "$id" reply_to
}

# The first line newer than the question in ME's own queue: tagged for ME, or redirected here.
# A line without text is never taken (and never deleted): afd_queue_first_after skips it.
_afd_ask_own_answer() {
    local q line text
    q="$(_afd_msg_dir)/$ME.jsonl"
    line=$(afd_queue_first_after "$q" "$NOTIF_ID"); [[ -n "$line" ]] || return 1
    text=$(afd_message_text "$line"); [[ -n "$text" ]] || return 1
    ANSWER_ID=$(afd_message_id "$line"); ANSWER="$text"; ANSWER_HOW=tagged
    _afd_line_true "$line" redirected && ANSWER_HOW=redirected
    afd_queue_delete "$q" "$ANSWER_ID"
    [[ -n "$ASK_M" ]] && { afd_release_claim "$ASK_M"; ASK_M=""; ASK_C=""; }   # back to the pool
    return 0
}

# _afd_ask_take_pooled <id> <how> — the pooled line <id> becomes the answer. A line without
# text is released, not consumed (review MINOR 5).
_afd_ask_take_pooled() {
    local line text
    line=$(afd_queue_get "$(_afd_pool_file)" "$1"); text=$(afd_message_text "$line")
    afd_release_claim "$1"; ASK_M=""; ASK_C=""
    [[ -n "$text" ]] || return 1
    ANSWER_ID="$1"; ANSWER="$text"; ANSWER_HOW="$2"
    afd_queue_delete "$(_afd_pool_file)" "$1"
}

# Claim the best pool line; take it, or ask the user back when another relay is waiting too.
# With another ask-back already open it asks for the message number (decided 2026-10-25).
_afd_ask_claim() {
    local pick tier id npend others
    pick=$(_afd_ask_scan candidate); [[ -n "$pick" ]] || return 1
    read -r tier id npend <<< "$pick"
    afd_claim "$id" "$ME" || return 1
    others=$(_afd_live_waiters | grep -vx -- "$ME" | head -1) || true
    if [[ "$tier" == 0 ]]; then _afd_ask_take_pooled "$id" reply_to; return; fi
    if [[ -z "$others" ]]; then _afd_ask_take_pooled "$id" single; return; fi
    if (( npend > 0 )); then
        ASK_C=$(_afd_ask_send "was #$id for me? y #$id / n #$id / @project #$id (another session is asking too)")
    else
        ASK_C=$(_afd_ask_send "was #$id for me? y / n / @project alone")
    fi
    if [[ -z "$ASK_C" ]]; then
        afd_release_claim "$id"
        echo "Could not ask on Telegram whether #$id was meant for $ME; will retry." >&2
        return 1
    fi
    ASK_M="$id"; _afd_ask_mark "claimed $ASK_M $ASK_C"
    echo "Asked on Telegram whether #$ASK_M was meant for $ME (#$ASK_C); waiting for y / n / @project..." >&2
    return 1
}

# Act on the user's verdict about the claimed line: y takes it, n rejects it, a project gets
# it. A bare verdict that is nobody's because another ask-back is open stays in the pool and
# earns one nudge per asked-about message, naming the numbered form.
_afd_ask_verdict() {
    local v kind target id rc=1
    v=$(_afd_ask_scan verdict); [[ -n "$v" ]] || return 1
    read -r kind target id <<< "$v"
    if [[ "$kind" == nudge ]]; then
        [[ "${ASK_NUDGED:-}" == "$ASK_M" ]] && return 1
        ASK_NUDGED="$ASK_M"
        _afd_ask_send "two sessions are asking - reply y #$ASK_M / n #$ASK_M" >/dev/null
        return 1
    fi
    afd_queue_delete "$(_afd_pool_file)" "$id"
    case "$kind" in
        yes) echo "Telegram: #$ASK_M is for $ME." >&2; _afd_ask_take_pooled "$ASK_M" confirmed && rc=0 ;;
        no)  echo "Telegram: #$ASK_M was not for $ME; waiting on." >&2
             afd_pool_reject "$ASK_M" "$ME"; afd_release_claim "$ASK_M" ;;
        redirect) echo "Telegram: #$ASK_M is for $target; re-filed there." >&2
             afd_pool_redirect "$ASK_M" "$target"; afd_release_claim "$ASK_M" ;;
    esac
    ASK_M=""; ASK_C=""; _afd_ask_mark
    return $rc
}

# afd_ask_confirm — design point 2 (decided 2026-10-25): after a confirmed or redirected
# answer, tell Telegram this session is working again.
afd_ask_confirm() {
    case "$ANSWER_HOW" in confirmed|redirected) _afd_ask_send "working on #$ANSWER_ID" >/dev/null ;; esac
    return 0
}

# afd_ask_cleanup — EXIT trap: drop the marker while it is still ours, and every claim we hold.
afd_ask_cleanup() {
    [[ "$(cut -d' ' -f1 "$MARKER" 2>/dev/null)" == "$$" ]] && rm -f "$MARKER"
    afd_release_claims_of "$$"
}
