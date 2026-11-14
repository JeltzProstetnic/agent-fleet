#!/usr/bin/env bash
# UserPromptSubmit hook: deactivate AFK + inject pending Telegram messages
# stdout from this hook IS added to Claude's context.
# CRITICAL: This hook runs on EVERY Enter press. It MUST be fast.
# Any network call MUST have a timeout — a hang here = "Interrupted..." for the user.
#
# CFG-770: AFK stays on through console typing until the user says "afk off"
# (decided 2026-10-18). Task notifications, subagent hand-backs, cross-session messages
# and scheduled fires also fire UserPromptSubmit and never end AFK, whatever they quote
# (hook_prompt_is_synthetic, lib-hook-stdin.sh). Every deactivation is logged to
# ~/.claude/logs/afk.log.
#
# CFG-1021: a typed `care` / `care off` that is the WHOLE message arms or ends session caretaking
# (§1b, lib-care.sh, its own state ~/.afd-care that AFK never changes); a Telegram-only
# `care off` ends it too (lib-afd-msg.sh).

AFD_CLI="${HOME}/.local/bin/afd"
AFK_LOG="$HOME/.claude/logs/afk.log"

INPUT=""
[[ -t 0 ]] || INPUT=$(timeout 2 cat 2>/dev/null)
# One field of the hook input JSON (bash 3.2 compatible: no NUL-split array read).
_field() {
  printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
v = d.get(sys.argv[1], "") if isinstance(d, dict) else ""
sys.stdout.write(v if isinstance(v, str) else "")' "$1" 2>/dev/null
}
PROMPT=$(_field prompt)
CWD=$(_field cwd)
[[ -n "$CWD" ]] || CWD="$PWD"

source "$(dirname "${BASH_SOURCE[0]}")/lib-afd-msg.sh" 2>/dev/null || true
source "$(dirname "${BASH_SOURCE[0]}")/lib-hook-stdin.sh" 2>/dev/null || true  # hook_prompt_is_synthetic
ME=$(afd_project_of "$CWD" 2>/dev/null || basename "$CWD")

# --- 1. Only a typed "afk off" ends AFK ---
# A harness-delivered turn never does, whatever it quotes: hand-backs, notifications,
# cross-session messages, and scheduled fires, known by the payload's `source` or a cron
# the Stop hook recorded. The test is shared with context-budget.sh's detectors (CFG-911).
# A partial deploy keeps a text test: an older lib-hook-stdin.sh its prompt_is_synthetic,
# no lib the pre-CFG-911 inline test; either way a typed "afk off" still ends AFK.
_afk_turn_synthetic() {
  if declare -F hook_prompt_is_synthetic >/dev/null; then
    hook_prompt_is_synthetic "$INPUT"
  elif declare -F prompt_is_synthetic >/dev/null; then
    prompt_is_synthetic "$PROMPT"
  else
    [[ "$PROMPT" =~ ^[[:space:]]*\<(task-notification|cross-session-message|agent-message) ]]
  fi
}
if [[ -f "$HOME/.afd-afk" ]] \
   && printf '%s' "$PROMPT" | grep -qiE '(^|[^[:alnum:]_])afk[[:space:]]+off([^[:alnum:]_]|$)' \
   && ! _afk_turn_synthetic; then
  rm -f "$HOME/.afd-afk"
  mkdir -p "$(dirname "$AFK_LOG")" 2>/dev/null
  echo "$(date +%Y-%m-%dT%H:%M:%S%z) deactivated by=afk-deactivate project=$ME trigger=afk-off" >> "$AFK_LOG" 2>/dev/null
  echo "AFK mode deactivated."
fi

# --- 1b. CFG-1021: a typed `care` / `care off` (the whole message) arms or ends caretaking ---
# lib-care.sh holds the state machine; a harness-delivered turn never arms or disarms (the same
# strict test as §1). On any turn it reminds the caretaker when its watch stopped beating. No
# care file and no care command: pure bash, nothing spawned. A partial deploy without the lib,
# or a bash older than 4.2, skips this step and changes nothing else.
SID=""
[[ "$INPUT" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && SID="${BASH_REMATCH[1]}"
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )) \
   && source "$(dirname "${BASH_SOURCE[0]}")/lib-care.sh" 2>/dev/null; then
  care_on_prompt "$PROMPT" "$ME" "$SID" _afk_turn_synthetic
fi

# --- 2. Inject this project's Telegram messages (others are queued for theirs) ---
MESSAGES=""
if [[ -x "$AFD_CLI" ]]; then
  if declare -F afd_route_messages >/dev/null; then
    FOREIGN=$(afd_route_messages "$ME")
    # A waiting AskUserQuestion relay owns this project's queue (2026-10-20, #406/#408).
    afd_question_waiting "$ME" || MESSAGES=$(afd_take_messages "$ME")
    for t in $FOREIGN; do
      case "$t" in
        afk:on)  echo "AFK switched ON from Telegram. Confirm it there: afd notify all \"[$ME] AFK is on\" --channel telegram" ;;
        afk:off) echo "AFK switched OFF from Telegram. Confirm it there: afd notify all \"[$ME] AFK is off\" --channel telegram" ;;
        care:off) echo "CARE_OFF: caretaking switched OFF from Telegram; AFK is unchanged. The caretaker is told by its watch or on its next turn, and runs §Stop of ~/.claude/knowledge/session-care.md. Confirm it there: afd notify all \"[$ME] care is off\" --channel telegram" ;;
        care:off:owner) echo "CARE_OFF: caretaking switched OFF from Telegram; AFK is unchanged. You were the caretaker: run §Stop of ~/.claude/knowledge/session-care.md now (TaskStop the watch first). Confirm it there: afd notify all \"[$ME] care is off\" --channel telegram" ;;
        care:off:none) echo "CARE_OFF from Telegram: caretaking was not on; nothing changed. Tell it there: afd notify all \"[$ME] care was not on\" --channel telegram" ;;
        care:off:failed) echo "CARE_OFF from Telegram FAILED: the care lock was busy, caretaking is unchanged. Tell it there: afd notify all \"[$ME] care off failed (busy) - send care off again\" --channel telegram" ;;
        *) echo "Telegram message(s) for @$t were queued for that project, not this one. Do not act on them. If a $t session is live (ListAgents), wake it with SendMessage: \"Telegram message(s) are queued for you; your prompt hook delivers them.\"" ;;
      esac
    done
  else
    echo "WARNING: lib-afd-msg.sh missing next to afk-deactivate.sh; Telegram messages are not routed per project."
    MESSAGES=$(timeout -k 2 3 "$AFD_CLI" messages 2>/dev/null)
  fi
  if [[ -n "$MESSAGES" ]]; then
    HAS_UNTAGGED=false
    LAST_PERSONA=""
    COLLECTED=""

    # Persona-agnostic: the channel a message arrived on is read from the message
    # itself, never hardcoded, so this works with whatever personas are configured
    # in foundation/personas.md. The server tags EVERY message with its bot's persona;
    # only one other than AFD_DEFAULT_PERSONA asks the model to switch persona.
    # A line the user redirected here through an ask-back (CFG-779) is addressed to
    # this project: labelled, and exempt from the untagged triage note.
    while IFS= read -r line; do
      msg=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null)
      ts=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('timestamp','')[:16])" 2>/dev/null)
      persona=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('persona','') or '')" 2>/dev/null)
      redirected=$(echo "$line" | python3 -c "import sys,json; print('(redirected here by the user) ' if json.load(sys.stdin).get('redirected') else '')" 2>/dev/null)
      # CFG-839: a Reply to this project's own message is addressed here too.
      [[ -z "$redirected" ]] && redirected=$(echo "$line" | ME="$ME" python3 -c "import sys,json,os; d=json.load(sys.stdin); print('(reply to #%s) ' % d.get('reply_to') if d.get('reply_to') and d.get('reply_to_project') == os.environ['ME'] else '')" 2>/dev/null)
      if [[ -n "$msg" ]]; then
        [[ "$msg" == @* || -n "$redirected" ]] || HAS_UNTAGGED=true
        if [[ -n "$persona" ]]; then
          COLLECTED="${COLLECTED}[$ts] ($persona channel) $redirected$msg"$'\n'
          [[ "$persona" != "${AFD_DEFAULT_PERSONA:-}" ]] && LAST_PERSONA="$persona"
        else
          COLLECTED="${COLLECTED}[$ts] $redirected$msg"$'\n'
        fi
      fi
    done <<< "$MESSAGES"

    if [[ -n "$COLLECTED" ]]; then
      echo ""
      echo "=== Telegram from ${AFD_USER_LABEL:-the user} ==="
      echo "$COLLECTED"
      if [[ -n "$LAST_PERSONA" ]]; then
        echo "ACTION: These arrived on the '$LAST_PERSONA' persona channel. Reply as that persona, then switch back."
        echo "Send reply: afd notify all \"<your reply>\" --channel telegram --persona $LAST_PERSONA"
      else
        echo "Reply via: afd notify all \"[$ME] your reply\" --channel telegram"
      fi
      if [[ "$HAS_UNTAGGED" == "true" ]]; then
        echo "NOTE: message(s) above are not addressed to a project (no @tag); this session got them first. Decide for each whether it is for $ME. If it is, act on it. If not, relay it verbatim to the right session with SendMessage (ListAgents for live sessions; if none is live, file it with inbox-file.sh), and tell the user on Telegram where it went, tagged [$ME]."
      fi
      echo "==="
    fi
  fi
fi

# --- 3. CFG-776: another project's queue nobody picked up → tell this model to wake it ---
# (SID was read from the payload in §1b.)
if declare -F afd_wake_hint >/dev/null; then
  afd_wake_hint "$ME" "$SID"
fi
