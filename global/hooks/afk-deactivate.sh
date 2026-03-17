#!/usr/bin/env bash
# UserPromptSubmit hook: deactivate AFK + inject pending messages
# stdout from this hook IS added to Claude's context.

AFD_CLI="${HOME}/.local/bin/afd"

# --- 0. Signal user is active (for secondary deactivation in PreToolUse) ---
date -Iseconds > "$HOME/.afd-user-active"

# --- 1. Deactivate AFK mode ---
if [[ -f "$HOME/.afd-afk" ]]; then
  rm -f "$HOME/.afd-afk"
  echo "AFK mode deactivated."
fi

# --- 2. Inject pending messages (if afd CLI available) ---
if [[ -x "$AFD_CLI" ]]; then
  MESSAGES=$("$AFD_CLI" messages 2>/dev/null)
  if [[ -n "$MESSAGES" ]]; then
    COLLECTED=""
    while IFS= read -r line; do
      msg=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null)
      ts=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('timestamp','')[:16])" 2>/dev/null)
      if [[ -n "$msg" ]]; then
        COLLECTED="${COLLECTED}[$ts] $msg"$'\n'
      fi
    done <<< "$MESSAGES"

    if [[ -n "$COLLECTED" ]]; then
      echo ""
      echo "=== Pending Messages ==="
      echo "$COLLECTED"
      echo "Reply via: afd notify all \"your reply\""
      echo "==="
    fi
  fi
fi
