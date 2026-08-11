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
    QUESTION=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('question',''))" 2>/dev/null)
    echo "AFK mode: routing question to Telegram..." >&2
    NL=$'\n'
    MSG="Question from Claude (AFK):${NL}${NL}${QUESTION}${NL}${NL}Reply with your answer."
    RESULT=$("$AFD_CLI" notify all "$MSG" --type permission --priority high 2>&1)
    NOTIF_ID=$(echo "$RESULT" | grep -oE '#[0-9]+' | sed 's/^#//')
    if [[ -z "$NOTIF_ID" ]]; then
        echo "Failed to route question to Telegram" >&2
        exit 2
    fi
    echo "Waiting for answer (#$NOTIF_ID)..." >&2
    ANSWER=$("$AFD_CLI" poll "$NOTIF_ID" --timeout ${AFD_AFK_TIMEOUT:-3600} 2>&1)
    if [[ $? -ne 0 || -z "$ANSWER" ]]; then
        echo "No answer received (timeout). Blocking." >&2
        exit 2
    fi
    # Return updatedInput with the user's answer injected as the question response
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"question":"%s"}}}' \
        "$(echo "$ANSWER" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip())[1:-1])" 2>/dev/null)"
    exit 0
fi

# Non-Bash tools: exit 0 with no output (CC treats empty stdout + exit 0 as hook_success)
if [[ "$INPUT" != *'"tool_name":"Bash"'* && "$INPUT" != *'"tool_name": "Bash"'* ]]; then
    exit 0
fi

# --- From here on, we know it's a Bash tool call ---

AFK_MARKER="$HOME/.afd-afk"
USER_ACTIVE_MARKER="$HOME/.afd-user-active"
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

# --- 1. Secondary AFK deactivation ---
# UserPromptSubmit doesn't fire for interrupt messages during agent execution.
# If user typed something (marker written by afk-deactivate.sh), deactivate AFK here.
if [[ -f "$AFK_MARKER" && -f "$USER_ACTIVE_MARKER" ]]; then
  if [[ "$USER_ACTIVE_MARKER" -nt "$AFK_MARKER" ]]; then
    rm -f "$AFK_MARKER" "$USER_ACTIVE_MARKER"
    echo "AFK mode deactivated (user returned)." >&2
    allow "AFK deactivated"
  fi
fi

# --- 2. AFK permission approval (only when AFK marker exists) ---
if [[ ! -f "$AFK_MARKER" ]]; then
  allow "not AFK"
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
  --type permission --priority high --ref "$CODE" 2>&1)

# Extract notification ID
NOTIF_ID=$(echo "$RESULT" | grep -oE '#[0-9]+' | sed 's/^#//')

if [[ -z "$NOTIF_ID" ]]; then
  echo "Failed to send permission request. Blocking command." >&2
  deny "Failed to send notification"
fi

echo "Waiting for approval (#$NOTIF_ID)..." >&2

# Poll for response (default 1 hour)
RESPONSE=$("$AFD_CLI" poll "$NOTIF_ID" --timeout ${AFD_AFK_TIMEOUT:-3600} 2>&1)
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
