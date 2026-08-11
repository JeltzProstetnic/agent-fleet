#!/usr/bin/env bash
# UserPromptSubmit hook: deactivate AFK + inject pending Telegram messages
# stdout from this hook IS added to Claude's context.
# CRITICAL: This hook runs on EVERY Enter press. It MUST be fast.
# Any network call MUST have a timeout — a hang here = "Interrupted..." for the user.

AFD_CLI="${HOME}/.local/bin/afd"

# --- 0. Signal user is active (for secondary deactivation in PreToolUse) ---
date +%Y-%m-%dT%H:%M:%S%z > "$HOME/.afd-user-active"

# --- 1. Deactivate AFK mode ---
if [[ -f "$HOME/.afd-afk" ]]; then
  rm -f "$HOME/.afd-afk"
  echo "AFK mode deactivated."
fi

# --- 2. Inject pending Telegram messages (if afd CLI available) ---
if [[ -x "$AFD_CLI" ]]; then
  MESSAGES=$(timeout 3 "$AFD_CLI" messages 2>/dev/null)
  if [[ -n "$MESSAGES" ]]; then
    LAST_PERSONA=""
    COLLECTED=""

    # Persona-agnostic: the channel a message arrived on is read from the message
    # itself, never hardcoded, so this works with whatever personas are configured
    # in foundation/personas.md.
    while IFS= read -r line; do
      msg=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null)
      ts=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('timestamp','')[:16])" 2>/dev/null)
      persona=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('persona','') or '')" 2>/dev/null)
      if [[ -n "$msg" ]]; then
        if [[ -n "$persona" ]]; then
          COLLECTED="${COLLECTED}[$ts] ($persona channel) $msg"$'\n'
          LAST_PERSONA="$persona"
        else
          COLLECTED="${COLLECTED}[$ts] $msg"$'\n'
        fi
      fi
    done <<< "$MESSAGES"

    if [[ -n "$COLLECTED" ]]; then
      echo ""
      echo "=== Incoming Telegram messages ==="
      echo "$COLLECTED"
      if [[ -n "$LAST_PERSONA" ]]; then
        echo "ACTION: These arrived on the '$LAST_PERSONA' persona channel. Switch to that persona to reply, then switch back."
        echo "Send reply: afd notify all \"<your reply>\" --channel telegram --persona $LAST_PERSONA"
      else
        echo "Reply via: afd notify all \"your reply\" --channel telegram"
      fi
      echo "==="
    fi
  fi
fi
