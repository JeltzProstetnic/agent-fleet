#!/usr/bin/env bash
# UserPromptSubmit hook: deactivate AFK + inject pending Telegram messages
# stdout from this hook IS added to Claude's context.

AFD_CLI="${HOME}/.local/bin/afd"

# --- 0. Signal user is active (for secondary deactivation in PreToolUse) ---
date -Iseconds > "$HOME/.afd-user-active"

# --- 1. Deactivate AFK mode ---
if [[ -f "$HOME/.afd-afk" ]]; then
  rm -f "$HOME/.afd-afk"
  echo "AFK mode deactivated."
fi

# --- 2. Inject pending Telegram messages ---
MESSAGES=$("$AFD_CLI" messages 2>/dev/null)
if [[ -n "$MESSAGES" ]]; then
  HAS_ELSA=false
  LAST_PERSONA=""
  COLLECTED=""

  while IFS= read -r line; do
    msg=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null)
    ts=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('timestamp','')[:16])" 2>/dev/null)
    persona=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('persona','') or '')" 2>/dev/null)
    if [[ -n "$msg" ]]; then
      if [[ "$persona" == "Elsa" ]]; then
        HAS_ELSA=true
        COLLECTED="${COLLECTED}[$ts] $msg"$'\n'
      else
        COLLECTED="${COLLECTED}[$ts] (Bartl channel) $msg"$'\n'
      fi
      LAST_PERSONA="$persona"
    fi
  done <<< "$MESSAGES"

  if [[ "$HAS_ELSA" == "true" ]]; then
    echo ""
    echo "=== Telegram from Matthias (via @ElsaXoBot) ==="
    echo "$COLLECTED"
    echo "ACTION: Switch to Elsa persona. Reply warmly to this message via Telegram."
    echo "Send reply: afd notify all \"<your Elsa reply>\" --channel telegram --persona Elsa"
    echo "After replying, switch back to previous persona."
    echo "==="
  elif [[ -n "$COLLECTED" ]]; then
    echo ""
    echo "=== Telegram from Matthias ==="
    echo "$COLLECTED"
    echo "Reply via: afd notify all \"your reply\" --channel telegram"
    echo "==="
  fi
fi
