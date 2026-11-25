#!/usr/bin/env bash
# afd-relay.sh — PreToolUse hook for message relay + AFK permission approval
# Fires on every tool call. Must be FAST for the common case (no queue, not AFK).
#
# Matcher: "" (match-all). CC 2.1.76+ fires "Bash"-matched hooks on ALL tools,
# producing "PreToolUse:Bash hook error" UI noise. Using match-all + self-filtering
# eliminates the error while keeping identical behavior.
#
# Functions:
# 1. Inject queued messages into Claude's context (stdout)
# 2. AFK mode: route dangerous Bash commands for approval
# 3. Report an AFK/DND switch made elsewhere since this session's last turn (CFG-1036) — on
#    Bash calls only: an AskUserQuestion call returns before that step, and setup/config/
#    settings.json registers this hook for the Bash and AskUserQuestion matchers, so any other
#    tool call learns of a switch at the next Bash call or at the prompt. A Bash call this hook
#    then BLOCKS gets the line on stderr too (deny), because Claude Code ignores stdout on exit 2.
#
# Protocol: exit 0 with empty stdout = allow; exit 2 with stderr = deny

# Read stdin first (must drain pipe before any exit)
# _python3 (lib-portable.sh, CFG-1087): on native Windows a bare python3 can be the Microsoft Store
# stub; everywhere else it is python3, unchanged. Fallback for a hooks dir without the lib.
source "$(dirname "${BASH_SOURCE[0]}")/lib-portable.sh" 2>/dev/null || true
type _python3 >/dev/null 2>&1 || _python3() { python3 "$@"; }

INPUT=$(cat)

# AskUserQuestion: route to Telegram when AFK (CFG-323)
if [[ "$INPUT" == *'"tool_name":"AskUserQuestion"'* || "$INPUT" == *'"tool_name": "AskUserQuestion"'* ]]; then
    AFK_MARKER="$HOME/.afd-afk"
    [[ ! -f "$AFK_MARKER" ]] && exit 0
    # CFG-1035: under DND nothing reaches the user, so the question is not relayed (Q-DND-ASK).
    DND_MARKER="$HOME/.afd-dnd"
    DND_ASK="DND is on (the user asked not to be disturbed): do not ask now, nothing reaches them until dnd off. Write this question into your handover with a stable ID (e.g. Q-<PROJECT>-<n>) and keep working. Only if you were meant to work unattended and can no longer work at all, tell them with: afd notify all \"[<project>] ...\" --channel telegram --critical"
    if [[ -f "$DND_MARKER" ]]; then echo "$DND_ASK" >&2; exit 2; fi
    AFD_CLI="${HOME}/.local/bin/afd"
    if [[ ! -x "$AFD_CLI" ]]; then
        echo "AFK mode active but afd CLI not found — cannot route question" >&2
        exit 2
    fi
    # lib-afd-ask.sh (answer handshake, CFG-779) pulls in lib-afd-msg.sh and lib-afd-scan.sh.
    # Without it a free-text Telegram answer could never be read, so fail fast to the console
    # instead of sending a question and waiting an hour for nothing.
    source "$(dirname "${BASH_SOURCE[0]}")/lib-afd-ask.sh" 2>/dev/null || true
    if ! declare -F afd_ask_step >/dev/null; then
        echo "AFK mode active but lib-afd-ask.sh (the Telegram answer reader) cannot load next to afd-relay.sh; the question was NOT sent. Ask in the console." >&2
        exit 2
    fi
    # CFG-1034: the wait (15 min in a care shift, else 45) and the record of every relayed
    # question and its outcome, which a Telegram `re-ask` reads (lib-afd-asked.sh).
    source "$(dirname "${BASH_SOURCE[0]}")/lib-afd-asked.sh" 2>/dev/null || true
    CWD=$(echo "$INPUT" | _python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)
    ME=$(afd_project_of "${CWD:-$PWD}" 2>/dev/null || basename "${CWD:-$PWD}")
    ASK_SID=""
    [[ "$INPUT" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && ASK_SID="${BASH_REMATCH[1]}"
    # The settings.json hook timeout (3720) must never fire first: a killed hook fails OPEN.
    if declare -F afd_asked_wait >/dev/null; then
        afd_asked_wait; WAIT=$ASK_WAIT; SPAN=$(afd_asked_span "$WAIT")
    else
        WAIT=2700; SPAN="45 min"
    fi
    _asked_end() { declare -F afd_asked_end >/dev/null && afd_asked_end "$NOTIF_ID" "$1" "$ASK_SID" "${2:-}"; return 0; }
    # Current CC schema is tool_input.questions[]; the old single 'question' field is kept as a fallback.
    QUESTION=$(echo "$INPUT" | _python3 -c "
import sys, json
t = json.load(sys.stdin).get('tool_input', {})
out = []
for q in t.get('questions') or []:
    out.append(q.get('question', ''))
    for i, o in enumerate(q.get('options') or [], 1):
        out.append(f'  {i}) {o.get(\"label\", \"\")}')
if not out and t.get('question'):
    out.append(t['question'])
print('\n'.join(out))" 2>/dev/null)
    echo "AFK mode: routing question to Telegram..." >&2
    NL=$'\n'
    TAG="$ME"; declare -F afd_short_name >/dev/null && TAG=$(afd_short_name "$ME")
    if [[ -n "$TAG" ]]; then
        HOW="start with @$TAG if more than one session is waiting"
    else
        HOW="reply untagged; no @tag routes to this project"
    fi
    MSG="[$ME] Question from Claude (AFK):${NL}${NL}${QUESTION}${NL}${NL}Reply with your answer as plain text ($HOW). Reply d to decline.${NL}I wait $SPAN, then go on with my own default; send re-ask to get the question back."
    RESULT=$("$AFD_CLI" notify all "$MSG" --channel telegram --type permission --priority high 2>&1)
    NOTIF_ID=$(echo "$RESULT" | grep -oE '#[0-9]+' | sed 's/^#//')
    if [[ -z "$NOTIF_ID" ]]; then
        # CFG-772: the server now answers 502 when Telegram rejects the message.
        echo "Failed to route question to Telegram (${RESULT:-no output}). The user did NOT receive it; tell them in the console and ask again later." >&2
        exit 2
    fi
    echo "Waiting for answer (#$NOTIF_ID)..." >&2
    # CFG-768: free text never reaches the notification's response (the server links
    # only a 4-letter code or "d"); it arrives as a plain message. A tagged or redirected
    # line comes from this project's queue; an untagged one is claimed from the shared
    # pool, with an ask-back when another relay waits too (lib-afd-ask.sh, CFG-779).
    # "d" still arrives through the notification. Only a message NEWER than the question
    # can answer it (ids share one sequence).
    MSG_DIR="${AFD_MSG_DIR:-$HOME/.afd-msgs}"
    # Marker = "<relay pid> <question id>" (+ "claimed <M> <C>" during an ask-back): other
    # hooks tell a live relay from a dead one's leftover by the pid, and leave untagged
    # lines to it. The EXIT trap removes it only while it is still ours (a second session
    # of this project may have taken it over) and drops any claim this relay holds.
    MARKER="$MSG_DIR/.waiting/$ME"
    mkdir -p "$MSG_DIR/.waiting" 2>/dev/null
    if declare -F afd_marker_write >/dev/null; then
        afd_marker_write "$MARKER" "$$ $NOTIF_ID"     # atomic: never seen empty
    else
        echo "$$ $NOTIF_ID" > "$MARKER"
    fi
    if declare -F afd_ask_cleanup >/dev/null; then
        trap 'afd_ask_cleanup' EXIT
    else
        trap '[[ "$(cut -d" " -f1 "$MARKER" 2>/dev/null)" == "$$" ]] && rm -f "$MARKER"' EXIT
    fi
    # The Claude Code process this question belongs to: when it is gone (Esc, /exit,
    # crash) nobody can receive the answer, so stop instead of eating the next reply.
    CC_PID="${AFD_RELAY_PARENT_PID:-}"
    [[ -z "$CC_PID" ]] && declare -F afd_claude_pid >/dev/null && CC_PID=$(afd_claude_pid)
    declare -F afd_asked_begin >/dev/null && afd_asked_begin "$NOTIF_ID" "$ME" "$ASK_SID" "$CC_PID" "$WAIT" "$QUESTION"
    DEADLINE=$(( $(date +%s) + WAIT ))
    ANSWER=""; ANSWER_ID=""; ANSWER_HOW=""
    declare -F afd_ask_begin >/dev/null && afd_ask_begin
    while (( $(date +%s) < DEADLINE )); do
        if [[ -n "$CC_PID" ]] && ! kill -0 "$CC_PID" 2>/dev/null; then
            _asked_end gone
            echo "Claude Code is gone; the Telegram question was abandoned." >&2
            exit 2
        fi
        # CFG-772(b): the user back at the keyboard ('afk off') releases the wait at once.
        if [[ ! -f "$AFK_MARKER" ]]; then
            _asked_end afk-off
            echo "AFK was switched off while this question waited for a Telegram answer. The user is back at the console: ask the question again now." >&2
            exit 2
        fi
        if [[ -f "$DND_MARKER" ]]; then
            _asked_end dnd
            echo "DND was switched on while this question (#$NOTIF_ID) waited. $DND_ASK" >&2
            exit 2
        fi
        R=$(timeout -k 2 15 "$AFD_CLI" poll "$NOTIF_ID" --timeout 1 2>/dev/null) || R=""
        if [[ "$R" == "denied" ]]; then
            _asked_end declined
            echo "The user declined to answer this question via Telegram (AFK). Do not ask again; continue without it." >&2
            exit 2
        elif [[ -n "$R" ]]; then
            ANSWER="$R"; break
        fi
        # The queue is peeked in place and the answer deleted by id (CFG-781): a kill
        # between two steps leaves every line inside some file, and older lines stay
        # queued for the next prompt hook instead of being requeued every cycle.
        if declare -F afd_ask_step >/dev/null; then
            afd_route_messages "$ME" >/dev/null
            afd_ask_step && break
        fi
        sleep "${AFD_AFK_POLL_INTERVAL:-5}"
    done
    if [[ -z "$ANSWER" ]]; then
        TOLD="No answer via Telegram within $SPAN (question #$NOTIF_ID). Do not ask it again now: take your own default decision and keep working. State that decision in one line of your reply, exactly in this form: AFK_DEFAULT #$NOTIF_ID: <your decision>. The user can bring the question back with re-ask on Telegram; a late answer then reaches you as a Telegram message."
        _asked_end timeout "$TOLD"
        echo "$TOLD" >&2
        exit 2
    fi
    _asked_end answered
    # CFG-779, design point 2: after a confirmed or redirected answer the session tells
    # Telegram "[proj] working on #M", so the user knows it is running again.
    declare -F afd_ask_confirm >/dev/null && afd_ask_confirm
    # CFG-773: answer the tool itself — updatedInput.answers + allow — so CC shows the
    # user's answer instead of "PreToolUse hook error" (afd_ask_map). Unmappable → the
    # block-reason delivery below, which works on every CC version.
    if declare -F afd_ask_map >/dev/null; then
        MAPPED=$(afd_ask_map "$INPUT" "$ANSWER" "${ANSWER_NOTE:-}") && [[ -n "$MAPPED" ]] && { printf '%s\n' "$MAPPED"; exit 0; }
    fi
    # Fallback: hand the answer to the model as the block reason (CFG-1039: with where it came from).
    echo "The user answered via Telegram (AFK)${ANSWER_NOTE:+, $ANSWER_NOTE}: \"$ANSWER\" — treat this as the user's answer to your question and continue; do not ask it again." >&2
    exit 2
fi

# PreToolUse stdout only reaches the model as hookSpecificOutput.additionalContext, so both
# notes below go out as ONE JSON object. CFG-1036: an AFK/DND switch made elsewhere since this
# session's last turn (lib-afd-mode.sh; pure bash when nothing changed). A subagent's call
# (agent_id in the payload) neither reports nor consumes it: the main thread must learn it.
# CFG-776: a BUSY session (tool calls, no prompts) also reports another project's undelivered
# Telegram queue, so an idle target gets woken. Fast path: no change and no queue files →
# no python.
_SID=""; _CWD=""; _CTX=""; _HD="${BASH_SOURCE[0]%/*}"
[[ "$_HD" == "${BASH_SOURCE[0]}" ]] && _HD=.
[[ "$INPUT" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && _SID="${BASH_REMATCH[1]}"
if ! [[ "$INPUT" =~ \"agent_id\"[[:space:]]*: ]] && source "$_HD/lib-afd-mode.sh" 2>/dev/null \
   && declare -F afd_mode_check >/dev/null; then
    afd_mode_check "$_SID"; _CTX="$AFD_MODE_LINES"
fi
if compgen -G "${AFD_MSG_DIR:-$HOME/.afd-msgs}/*.jsonl" >/dev/null 2>&1; then
    source "$_HD/lib-afd-msg.sh" 2>/dev/null || true
    if declare -F afd_wake_hint >/dev/null; then
        [[ "$INPUT" =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && _CWD="${BASH_REMATCH[1]}"
        _HINT=$(afd_wake_hint "$(afd_project_of "${_CWD:-$PWD}" 2>/dev/null || basename "${_CWD:-$PWD}")" "$_SID")
        [[ -n "$_HINT" ]] && _CTX="${_CTX:+$_CTX$'\n'}$_HINT"
    fi
fi
[[ -n "$_CTX" ]] && _python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":sys.argv[1]}}))' "$_CTX"

# Non-Bash tools: exit 0 (CC treats exit 0 without a decision as hook_success)
if [[ "$INPUT" != *'"tool_name":"Bash"'* && "$INPUT" != *'"tool_name": "Bash"'* ]]; then
    exit 0
fi

# --- From here on, we know it's a Bash tool call ---

AFK_MARKER="$HOME/.afd-afk"
AFD_CLI="${HOME}/.local/bin/afd"

# Allow: exit 0 with no stdout (CC treats empty stdout + exit 0 as hook_success)
allow() {
  exit 0
}

# Deny: exit 2 with reason on stderr (CC reads stderr for blocking error message). On exit 2
# Claude Code ignores the stdout JSON, so a mode line already marked seen goes to stderr as well.
deny() {
  local reason="${1:-Blocked by hook}"
  [[ -n "${_CTX:-}" ]] && echo "$_CTX" >&2
  echo "$reason" >&2
  exit 2
}

# --- 1. No secondary deactivation: AFK stays on until the user says "afk off"
# (CFG-770, 2026-10-18), which afk-deactivate.sh handles. ---

# --- 2. AFK permission approval (only when AFK marker exists) ---
if [[ ! -f "$AFK_MARKER" ]]; then
  allow "not AFK"
fi

# --- 3. Auto mode: CC's classifier gates Bash — no Telegram relay (CFG-768) ---
# The relay outlived CC's 60 s hook timeout, failed open, and the command ran
# anyway: prompts reached Telegram that gated nothing. AskUserQuestion is
# still routed above.
if [[ "$INPUT" =~ \"permission_mode\"[[:space:]]*:[[:space:]]*\"auto\" ]]; then
  allow "auto mode"
fi

COMMAND=$(echo "$INPUT" | _python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)
DESCRIPTION=$(echo "$INPUT" | _python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('description',''))" 2>/dev/null)

# Safe commands that never need approval (even in AFK)
SAFE_PATTERNS=(
  "^ls " "^cat " "^echo " "^which " "^head " "^tail " "^grep " "^find "
  "^git " "^date " "^pwd" "^wc " "^stat " "^du " "^readlink " "^basename "
  "^dirname " "^realpath " "^test " "^printf " "^afd " "^node "
  "^diff " "^sort " "^ssh " "^jq "
)

for pattern in "${SAFE_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qE "$pattern"; then
    allow "safe command"
  fi
done

# CFG-1035: under DND no approval can be asked on Telegram (the request would only be held).
if [[ -f "$HOME/.afd-dnd" ]]; then
  deny "DND is on: this command needs the user's approval on Telegram (AFK), which cannot be asked until dnd off. Write it into your handover with a stable ID and keep working on what needs no approval. Only if you were meant to work unattended and can no longer work at all, tell the user with: afd notify all \"[<project>] ...\" --channel telegram --critical"
fi

# Dangerous command in AFK mode — requires approval
# If afd CLI is available, send notification for approval
if [[ ! -x "$AFD_CLI" ]]; then
  deny "AFK mode active but afd CLI not found — blocking dangerous command"
fi

echo "AFK mode: requesting approval for command..." >&2

# Generate random 4-letter approval code
CODE=$(_python3 -c "import random,string; print(''.join(random.choices(string.ascii_lowercase, k=4)))")

# Send permission request
NL=$'\n'
MSG="Permission needed (AFK):${NL}${NL}${DESCRIPTION:+$DESCRIPTION$NL}"
MSG="${MSG}${NL}\`${COMMAND}\`${NL}${NL}Approve: reply \`${CODE}\` | Deny: reply \`d\`"
RESULT=$("$AFD_CLI" notify all "$MSG" \
  --type permission --priority high --channel telegram --ref "$CODE" 2>&1)

# Extract notification ID
NOTIF_ID=$(echo "$RESULT" | grep -oE '#[0-9]+' | sed 's/^#//')

if [[ -z "$NOTIF_ID" ]]; then
  echo "Failed to send permission request. Blocking command." >&2
  deny "Failed to send notification"
fi

echo "Waiting for approval (#$NOTIF_ID)..." >&2

# Poll for response (default 1 hour)
# Hard-bounded below the settings.json hook timeout (3720): a killed hook fails OPEN.
RESPONSE=$(timeout -k 5 "${AFD_AFK_TIMEOUT:-3600}" "$AFD_CLI" poll "$NOTIF_ID" --timeout $(( ${AFD_AFK_TIMEOUT:-3600} > 60 ? ${AFD_AFK_TIMEOUT:-3600} - 30 : ${AFD_AFK_TIMEOUT:-3600} )) 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 && "$RESPONSE" == "approved" ]]; then
  echo "Approved" >&2
  allow "approved"
elif [[ "$RESPONSE" == "denied" ]]; then
  echo "Denied" >&2
  deny "denied"
else
  echo "No response (timeout). Blocking command." >&2
  deny "timeout"
fi
