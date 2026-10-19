#!/usr/bin/env bash
# afd-relay.sh — PreToolUse hook for message relay + AFK permission approval
# Fires on every tool call. Must be FAST for the common case (no queue, not AFK).
#
# Matcher: "" (match-all). CC 2.1.76+ fires "Bash"-matched hooks on ALL tools,
# producing "PreToolUse:Bash hook error" UI noise. Using match-all + self-filtering
# eliminates the error while keeping identical behavior.
#
# Two functions:
# 1. Inject queued messages into Claude's context (stdout)
# 2. AFK mode: route dangerous Bash commands for approval
#
# Protocol: exit 0 with empty stdout = allow; exit 2 with stderr = deny

# Read stdin first (must drain pipe before any exit)
INPUT=$(cat)

# AskUserQuestion: route to Telegram when AFK (CFG-323)
if [[ "$INPUT" == *'"tool_name":"AskUserQuestion"'* || "$INPUT" == *'"tool_name": "AskUserQuestion"'* ]]; then
    AFK_MARKER="$HOME/.afd-afk"
    [[ ! -f "$AFK_MARKER" ]] && exit 0
    AFD_CLI="${HOME}/.local/bin/afd"
    if [[ ! -x "$AFD_CLI" ]]; then
        echo "AFK mode active but afd CLI not found — cannot route question" >&2
        exit 2
    fi
    source "$(dirname "${BASH_SOURCE[0]}")/lib-afd-msg.sh" 2>/dev/null || true
    CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)
    ME=$(afd_project_of "${CWD:-$PWD}" 2>/dev/null || basename "${CWD:-$PWD}")
    # Current CC schema is tool_input.questions[]; the old single 'question' field is kept as a fallback.
    QUESTION=$(echo "$INPUT" | python3 -c "
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
    MSG="[$ME] Question from Claude (AFK):${NL}${NL}${QUESTION}${NL}${NL}Reply with your answer as plain text (start with @$TAG if more than one session is waiting). Reply d to decline."
    RESULT=$("$AFD_CLI" notify all "$MSG" --channel telegram --type permission --priority high 2>&1)
    NOTIF_ID=$(echo "$RESULT" | grep -oE '#[0-9]+' | sed 's/^#//')
    if [[ -z "$NOTIF_ID" ]]; then
        # CFG-772: the server now answers 502 when Telegram rejects the message.
        echo "Failed to route question to Telegram (${RESULT:-no output}). The user did NOT receive it; tell them in the console and ask again later." >&2
        exit 2
    fi
    echo "Waiting for answer (#$NOTIF_ID)..." >&2
    # CFG-768: free text never reaches the notification's response (the server links
    # only a 4-letter code or "d"); it arrives as a plain message, so take it from
    # this project's message queue. "d" still arrives through the notification.
    # Only a message NEWER than the question can answer it (ids share one sequence).
    # While waiting, a marker lets any session route an untagged reply here.
    MSG_DIR="${AFD_MSG_DIR:-$HOME/.afd-msgs}"
    mkdir -p "$MSG_DIR/.waiting" 2>/dev/null && echo "$NOTIF_ID" > "$MSG_DIR/.waiting/$ME"
    trap 'rm -f "$MSG_DIR/.waiting/$ME"' EXIT
    WAIT=${AFD_AFK_TIMEOUT:-3600}
    # End 30 s early: the settings.json hook timeout (3720) must never fire first,
    # because a killed hook fails OPEN.
    (( WAIT > 60 )) && WAIT=$(( WAIT - 30 ))
    DEADLINE=$(( $(date +%s) + WAIT ))
    ANSWER=""
    while (( $(date +%s) < DEADLINE )); do
        # CFG-772(b): MG back at the keyboard ('afk off') releases the wait at once.
        if [[ ! -f "$AFK_MARKER" ]]; then
            echo "AFK was switched off while this question waited for a Telegram answer. The user is back at the console: ask the question again now." >&2
            exit 2
        fi
        R=$(timeout -k 2 15 "$AFD_CLI" poll "$NOTIF_ID" --timeout 1 2>/dev/null) || R=""
        if [[ "$R" == "denied" ]]; then
            echo "The user declined to answer this question via Telegram (AFK). Do not ask again; continue without it." >&2
            exit 2
        elif [[ -n "$R" ]]; then
            ANSWER="$R"; break
        fi
        if declare -F afd_route_messages >/dev/null; then
            afd_route_messages "$ME" >/dev/null
            QUEUED=$(afd_take_messages "$ME")
            KEEP=""
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                if [[ -z "$ANSWER" ]] && (( $(afd_message_id "$line") > NOTIF_ID )); then
                    ANSWER=$(afd_message_text "$line")
                    [[ -n "$ANSWER" ]] && continue
                fi
                KEEP="$KEEP$line"$'\n'
            done <<< "$QUEUED"
            [[ -n "$KEEP" ]] && printf '%s' "$KEEP" >> "$MSG_DIR/$ME.jsonl"
            [[ -n "$ANSWER" ]] && break
        fi
        sleep "${AFD_AFK_POLL_INTERVAL:-5}"
    done
    if [[ -z "$ANSWER" ]]; then
        echo "No answer received via Telegram (timeout). Ask again when the user is back." >&2
        exit 2
    fi
    # Hand the answer to the model as the block reason: version-proof, unlike
    # rewriting the tool input (validated as tool input from CC 2.1.300).
    echo "The user answered via Telegram (AFK): \"$ANSWER\" — treat this as the user's answer to your question and continue; do not ask it again." >&2
    exit 2
fi

# CFG-776: a BUSY session (tool calls, no prompts) also reports another project's
# undelivered Telegram queue, so an idle target gets woken. PreToolUse stdout only
# reaches the model as hookSpecificOutput.additionalContext. Fast path: no queue
# files → nothing sourced, no python.
if compgen -G "${AFD_MSG_DIR:-$HOME/.afd-msgs}/*.jsonl" >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/lib-afd-msg.sh" 2>/dev/null || true
    if declare -F afd_wake_hint >/dev/null; then
        _SID=""; _CWD=""
        [[ "$INPUT" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && _SID="${BASH_REMATCH[1]}"
        [[ "$INPUT" =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && _CWD="${BASH_REMATCH[1]}"
        _HINT=$(afd_wake_hint "$(afd_project_of "${_CWD:-$PWD}" 2>/dev/null || basename "${_CWD:-$PWD}")" "$_SID")
        [[ -n "$_HINT" ]] && python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":sys.argv[1]}}))' "$_HINT"
    fi
fi

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

# Deny: exit 2 with reason on stderr (CC reads stderr for blocking error message)
deny() {
  local reason="${1:-Blocked by hook}"
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

COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)
DESCRIPTION=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('description',''))" 2>/dev/null)

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

# Dangerous command in AFK mode — requires approval
# If afd CLI is available, send notification for approval
if [[ ! -x "$AFD_CLI" ]]; then
  deny "AFK mode active but afd CLI not found — blocking dangerous command"
fi

echo "AFK mode: requesting approval for command..." >&2

# Generate random 4-letter approval code
CODE=$(python3 -c "import random,string; print(''.join(random.choices(string.ascii_lowercase, k=4)))")

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
